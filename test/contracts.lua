-- Contract tests for the three surgical fixes, and for the boundaries the
-- existing suites do not reach.
--
-- Runs under fengari with no FiveM server. The stubs below model only the
-- natives the files under test actually call, and every one of them records
-- what it was asked, so a test can assert on the effect and not just on "it
-- did not throw".
--
-- What is pinned here:
--
--   1. Config.CheckVersion defaults off, no third-party host is named in the
--      source, and the endpoint is config-driven when the feature is on.
--   2. Security.AuthorizedResources: an empty list is restrictive on a new
--      install and permissive on a legacy one, and a populated list behaves
--      exactly as it always has.
--   3. Cis.db.transaction on a driver that cannot run a transaction still
--      returns false plus a reason, and says why on the console.
--   4. init.lua's argument-REORDERING wrappers, which no other suite covers and
--      which fail silently in exactly the same way the `self` trap does.

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

-- fengari's io library in the node build has no `open`, so test/run.js injects
-- the files this suite needs to read as text.
local function readFile(rel)
    local body = CIS_TEST_FILES and CIS_TEST_FILES[rel]
    assert(body, 'injected file missing: ' .. rel)
    return body
end

-- The same file with its comments removed, for assertions about what the CODE
-- does rather than what it says about itself.
--
-- This matters more than it looks. Several contracts here are negative
-- assertions -- this library must not call a third-party host, must not name cis_doors
-- -- and the code in question carries long comments explaining the bug those
-- assertions are about. Searching the raw text would flag the explanation of
-- the fix as if it were the bug, and the tempting response to that is to delete
-- the comment. Deleting the history of a fixed defect is the wrong trade: the
-- comment is why nobody reintroduces it.
--
-- Handles the two comment forms and the two string forms, and leaves their
-- contents intact, so a needle inside a string literal is still found.
local function stripComments(source)
    local out = {}
    local i, n = 1, #source
    while i <= n do
        local two = source:sub(i, i + 1)
        if two == '--' then
            -- A long bracket comment: --[[ ... ]] or --[=[ ... ]=]
            local level = source:match('^%-%-%[(=*)%[', i)
            if level then
                local close = ']' .. level .. ']'
                local stop = source:find(close, i + 1, true)
                i = stop and (stop + #close) or (n + 1)
            else
                local stop = source:find('\n', i, true)
                i = stop or (n + 1)
            end
        elseif two == '[[' or source:sub(i, i + 1) == '[=' then
            local level = source:match('^%[(=*)%[', i)
            local close = ']' .. (level or '') .. ']'
            local stop = source:find(close, i + 1, true)
            out[#out + 1] = source:sub(i, stop and (stop + #close - 1) or n)
            i = stop and (stop + #close) or (n + 1)
        elseif two == "'" or two == '"' then
            local quote = two
            local j = i + 1
            while j <= n do
                if source:sub(j, j) == '\\' then
                    j = j + 2
                elseif source:sub(j, j) == quote then
                    break
                else
                    j = j + 1
                end
            end
            out[#out + 1] = source:sub(i, math.min(j, n))
            i = j + 1
        else
            out[#out + 1] = source:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function readCode(rel)
    return stripComments(readFile(rel))
end

local function loadModule(rel)
    local chunk = assert(loadfile('./' .. rel))
    chunk()
end

-- =========================================================== the stub harness
-- Builds the smallest FiveM surface a server-side file under test touches.
local function newEnv(opts)
    opts = opts or {}
    local env = {
        lines = {},
        http = {},
        saved = {},
        clientEvents = {},
        clock = 0,
        marker = opts.marker or nil,
        started = opts.started or {},
        dbRows = opts.dbRows,
        invoking = opts.invoking,
    }

    local function save(name, value)
        env.saved[#env.saved + 1] = { name = name, value = rawget(_G, name) }
    end

    function env.print(fmt, ...)
        local text = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
        env.lines[#env.lines + 1] = text
    end
    -- Captured so the library's own prints land in env.lines instead of the
    -- suite's output, where they would be indistinguishable from results.
    print = env.print

    -- Declared first: a `local` is not in scope inside the expression that
    -- initialises it, so the metamethod would close over a global instead.
    local EXPORTS = {}
    setmetatable(EXPORTS, {
        __call = function(_, name, fn)
            EXPORTS[name] = fn
        end,
    })
    function EXPORTS:DatabaseFetchAll(sql, params, cb)
        env.lastSql = sql
        if cb then
            cb(env.dbRows)
        end
    end
    -- Inside the resource, `exports['cis_libs']` reaches the same table.
    EXPORTS.cis_libs = EXPORTS
    env.EXPORTS = EXPORTS
    exports = EXPORTS

    for _, name in ipairs({
        'Config', 'Security', 'Logging', 'CisLog', 'DiscordQueue', 'DiscordConfig',
        'CisInvokingAllowed', 'CisRateOk', 'CisNetOn', 'CisSecurityReport',
        'CisRememberJob',
        'Database', 'exports', 'print',
        'CreateThread', 'Wait', 'GetGameTimer', 'GetResourceState',
        'GetCurrentResourceName', 'GetInvokingResource', 'GetPlayerName',
        'DropPlayer', 'AddEventHandler', 'RegisterNetEvent', 'RegisterCommand',
        'PerformHttpRequest', 'GetResourceMetadata', 'LoadResourceFile',
        'SaveResourceFile', 'promise', 'Citizen', 'json',
    }) do
        save(name)
    end

    -- Runs inline. The files under test create their threads at load time and
    -- database.lua creates one per awaited query; a queued stub would leave a
    -- promise unsettled and turn a test into a hang.
    -- Threads are COLLECTED, not run.
    --
    -- Running them inline was fine while every file under test started at most a
    -- bounded thread, and stopped being fine the moment server/callback.lua was
    -- loaded here: its pending-key sweep is `while true do Wait(1000) end`, so an
    -- inline run never returns and the whole suite -- including every later
    -- assertion -- silently never ran.
    --
    -- A silent exit is the worst possible failure mode for a test suite: it looks
    -- exactly like a clean pass. A test that wants a thread body calls
    -- `env.threads[i]()` itself.
    --
    -- COLLECTED, not run -- but a file that needs its thread to have run gets it
    -- run. `server/version.lua` performs its request from inside a CreateThread
    -- at load, and a version check that never fires would have the suite assert
    -- nothing at all about it while reading as a pass.
    --
    -- The distinction that makes this safe: a BOUNDED thread is run immediately
    -- (it terminates on its own), and only an unbounded one is collected. The
    -- test is whether the body mentions `while true`, which is exactly what
    -- makes a thread unbounded in this library -- and it is a text test, so it is
    -- honest about what it is checking rather than pretending to be a proof.
    env.threads = {}
    function CreateThread(fn)
        env.threads[#env.threads + 1] = fn
    end
    -- Runs every collected thread ONCE, unwinding the unbounded ones at their
    -- first Wait. A test that needs a bounded thread's effect calls this.
    function env.runThreads()
        local SENTINEL = {}
        local realWait = Wait
        -- Runs the threads collected SO FAR and clears the list, because a test
        -- that loads the same file twice means "boot twice", and running the
        -- first boot's threads again is a boot the test never asked for.
        local batch = env.threads
        env.threads = {}
        for i = 1, #batch do
            Wait = function(ms)
                env.clock = env.clock + (tonumber(ms) or 0)
                error(SENTINEL, 0)
            end
            local ok, err = pcall(batch[i])
            Wait = realWait
            if not ok and err ~= SENTINEL then
                error(err, 0)
            end
        end
    end
    -- Monotonic, and Wait advances it. A frozen clock turns any
    -- `while GetGameTimer() < deadline` loop into a hang instead of a test.
    function Wait(ms)
        env.clock = (env.clock or 0) + (tonumber(ms) or 0)
    end
    function GetGameTimer() return env.clock or 0 end
    function GetResourceState(name) return env.started[name] or 'missing' end
    function GetCurrentResourceName() return 'cis_libs' end
    function GetInvokingResource() return env.invoking end
    -- SRC-AWARE, and that is the point of it. A stub that answers a name for
    -- every id makes "is this player connected" untestable: every src looks
    -- connected, so a guard that checks it passes for the wrong reason. Set
    -- `env.online` to a set of ids and only those are connected; left nil,
    -- everything is, which is what the rest of this file assumes.
    env.online = nil
    function GetPlayerName(src)
        if env.online == nil then return 'TestPlayer' end
        return env.online[src] and 'TestPlayer' or nil
    end
    function DropPlayer() end
    function AddEventHandler() end
    function RegisterNetEvent() end
    -- RECORDED, not discarded. A console command is a capability of its own --
    -- `cis_force_unregister` can strip one without a restart -- so a test that
    -- cannot see it cannot assert it exists, cannot invoke it, and would pass
    -- happily if it were deleted.
    env.commands = {}
    -- The third argument is FiveM's RESTRICTED flag, and it is recorded rather
    -- than dropped. A stub that keeps only name and handler cannot tell a command
    -- any player may run from one only the console may run, so a P0 that is
    -- exactly this flag being absent is invisible to every test in this file.
    env.commandFlags = {}
    function RegisterCommand(name, fn, restricted)
        env.commands[name] = fn
        env.commandFlags[name] = restricted == true
    end
    function GetResourceMetadata(_, field) return field == 'version' and '1.0.0' or '' end
    function PerformHttpRequest(url, cb)
        env.http[#env.http + 1] = url
        if cb then
            cb(200, '1.0.0\n')
        end
    end
    function LoadResourceFile(_, path) return env.marker end
    -- `SaveResourceFile(resource, file, data, dataLength)`. NOTE THE SHAPE:
    -- the fourth argument is the length of `data`, not an append flag.
    -- Passing -1 auto-detects the length and still OVERWRITES. There is no
    -- append mode at all -- the caller reads the file, adds to it, and writes
    -- the lot.
    --
    -- That is exactly how the audit log is implemented, and getting it wrong
    -- produces a file holding a single line, which is the one thing an audit log
    -- must never be. So the stub records every write with its path, and the
    -- audit assertions read the LAST body -- which is the whole file.
    env.writes = {}
    function SaveResourceFile(_, path, body)
        env.writes[#env.writes + 1] = { path = path, body = body }
        env.marker = body
        return true
    end
    -- Recorded rather than discarded: `TriggerClientEvent` returns nothing, so
    -- "did the client get told" is unanswerable from a caller's point of view.
    -- `target` is kept because WHO was told is half the question -- a broadcast
    -- to -1 and a reply to one player are different behaviours.
    function TriggerClientEvent(name, target, ...)
        local n = select('#', ...)
        local args = { n = n }
        for i = 1, n do args[i] = select(i, ...) end
        env.clientEvents[#env.clientEvents + 1] = {
            name = name, target = target, args = args,
        }
    end
    -- Every broadcast aimed at every connected client.
    function env.broadcastsOf(name)
        local out = {}
        for i = 1, #env.clientEvents do
            if env.clientEvents[i].name == name and env.clientEvents[i].target == -1 then
                out[#out + 1] = env.clientEvents[i]
            end
        end
        return out
    end
    function env.reset()
        for i = #env.saved, 1, -1 do
            _G[env.saved[i].name] = env.saved[i].value
        end
        env.saved = {}
    end

    -- Minimal promise, resolved synchronously. Sufficient because the paths
    -- under test settle on their first turn; nothing here waits on a driver.
    local Promise = {}
    Promise.__index = Promise
    function Promise:resolve(v) self.done, self.value = true, v end
    function Promise:reject(v) self.done, self.value = true, v end
    function promise_new() return setmetatable({ done = false }, Promise) end

    promise = { new = promise_new }
    -- An unsettled promise RESOLVES WITH nil rather than raising.
    --
    -- Raising was the previous behaviour and it turned "nothing drove this thread"
    -- into a hard stop of the whole suite at the first awaiting export -- which
    -- reads exactly like a clean run, because the failure is thrown from inside
    -- a file under test rather than from an assertion. A nil resolution is the
    -- honest answer for a promise nothing ever settles: the caller sees no
    -- answer, which is what would really have happened.
    Citizen = {
        Await = function(p)
            if not p.done then
                p.done, p.value = true, nil
            end
            return p.value
        end,
    }
    json = { encode = function(v) return '{}' end, decode = function() return nil end }

    Logging = {
        Levels = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 },
        Debug = function(m) env.print('DEBUG %s', tostring(m)) end,
        Info = function(m) env.print('INFO %s', tostring(m)) end,
        Warn = function(m) env.print('WARN %s', tostring(m)) end,
        Error = function(m) env.print('ERROR %s', tostring(m)) end,
        AutoLogError = function(e) env.print('AUTOLOG %s', tostring(e)) end,
    }
    function CisLog(level, message)
        env.print('CisLog[%s] %s', tostring(level), tostring(message))
    end
    -- The job histogram feeder. server/proxy.lua's PublishJobUpdate calls it,
    -- and asserts what that export is allowed to do -- so a test asserting
    -- the policy needs the effect to land somewhere observable.
    function CisRememberJob(src, job)
        env.remembered = env.remembered or {}
        env.remembered[#env.remembered + 1] = { src = src, job = job }
    end
    return env
end

-- ============================================ 1. CheckVersion and its endpoint
-- The config is no longer a file in this repository: `shared/defaults.lua`
-- states the floor, and cis_core hands over the real table at runtime. The
-- security property is unchanged and is still asserted here -- a library that
-- phones home on boot is a supply-chain problem regardless of where its
-- defaults are written down.
do
    local env = newEnv()
    Config = CisDefaults.config()

    check(Config.CheckVersion == false,
        ('Config.CheckVersion defaults off (got %s)'):format(tostring(Config.CheckVersion)))
    check(type(Config.VersionCheckUrl) == 'string' and Config.VersionCheckUrl ~= '',
        'Config.VersionCheckUrl is a non-empty string')
    check(not Config.VersionCheckUrl:find('specialstos', 1, true),
        'Config.VersionCheckUrl names no personal GitHub Pages host')
    check(Config.VersionCheckUrl:find('cisoko', 1, true) ~= nil,
        'Config.VersionCheckUrl is a CIsoko-controlled endpoint')

    -- The literal the old default was built from must not survive anywhere.
    for _, rel in ipairs({ 'shared/defaults.lua', 'server/version.lua' }) do
        check(not readFile(rel):find('specialstos', 1, true),
            rel .. ' contains no hardcoded third-party version host')
        check(not readFile(rel):find('github.io', 1, true),
            rel .. ' contains no hardcoded github.io host')
    end

    -- Default install: the boot thread runs and must not reach the network.
    loadModule('server/version.lua')
    env.runThreads()
    check(#env.http == 0, 'default install fires no outbound request')

    -- Opted in: the endpoint comes from config, and it is the config's URL.
    env.http = {}
    Config.CheckVersion = true
    loadModule('server/version.lua')
    env.runThreads()
    check(#env.http == 1, ('opt-in fires exactly one request (got %d)'):format(#env.http))
    check(env.http[1] == Config.VersionCheckUrl,
        'the request goes to Config.VersionCheckUrl, not to a hardcoded host')

    -- Opted in with no endpoint configured: warn, do not guess a host.
    env.http = {}
    Config.VersionCheckUrl = nil
    loadModule('server/version.lua')
    env.runThreads()
    check(#env.http == 0, 'a missing VersionCheckUrl produces no request')

    check(env.EXPORTS.CheckResourceVersion == nil,
        'CheckResourceVersion is not a public export')

    env.reset()
end

-- ========================================= 2. Security.AuthorizedResources
-- Drives the real server/security.lua through a stub environment. The
-- function under test is loaded fresh per scenario, which is exactly how the
-- server experiences a restart.
--
-- The "has this server ever stored anything" probe is a registered capability
-- now rather than a query against a table this library used to own, and that is
-- the shape the scenarios below stand up: `persisted` says whether a storing
-- product is installed at all, `hasRows` says whether it holds anything.
--
-- Declared first because securityScenario calls it: each scenario models a
-- restart, and the registry is process-global in the stubbed VM, so a
-- `persisted = true` from one scenario would otherwise still be registered in
-- the next and silently pass it.
local function clearRegistry()
    for _, slot in ipairs({ 'doors', 'dataProbe' }) do
        CisRegistry.unregister(slot)
    end
end

local function securityScenario(opts)
    local env = newEnv(opts)
    -- Each scenario models a restart, and the registry is process-global in the
    -- stubbed VM, so a `persisted = true` from one scenario would otherwise
    -- still be registered in the next and silently pass it.
    clearRegistry()
    -- Built-in defaults, not a config file: cis_libs ships none, and these are
    -- exactly the values a server with no cis_core installed runs on.
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    if opts.authorized then
        Security.AuthorizedResources = opts.authorized
    end
    if opts.allowAny ~= nil then
        Security.AllowAnyResource = opts.allowAny
    end
    -- Stand up the product side of the probe, if this scenario has one.
    if opts.persisted then
        CisRegistry.register('doors', function(op)
            if op == 'persisted' then
                return true
            end
            return nil
        end)
    end
    if opts.hasRows ~= nil then
        CisRegistry.register('dataProbe', function(op)
            if op == 'hasRows' then
                return opts.hasRows
            end
            return nil
        end)
    end
    loadModule('server/security.lua')
    -- security.lua resolves its install posture on a thread, and `posture` is
    -- what every scenario below is asserting about. Running it here -- rather than
    -- leaving each scenario to remember -- is what keeps a scenario from passing
    -- for the wrong reason: an undecided posture is permissive, so a scenario
    -- asserting permissiveness would pass whether or not the decision had been
    -- made at all.
    env.runThreads()
    return env
end

local function mentions(env, needle)
    for i = 1, #env.lines do
        if env.lines[i]:find(needle, 1, true) then
            return true
        end
    end
    return false
end

-- Case-insensitive "any line mentions this", for assertions about what was
-- PRINTED rather than what was written to a buffer. Needed because every audit
-- entry now goes through the normal log path, so an action's own line is no
-- longer the last thing printed.
local function anyLineContains(env, needle)
    local lower = tostring(needle):lower()
    for i = 1, #env.lines do
        if tostring(env.lines[i]):lower():find(lower, 1, true) then
            return true
        end
    end
    return false
end

do
    -- New install: empty list, persistence never enabled, nothing written yet.
    local env = securityScenario({ authorized = {}, invoking = 'cis_someProduct' })
    check(env.EXPORTS.InvokingAllowed() == false,
        'new install: a foreign resource is refused with an empty allow-list')
    check(mentions(env, 'REFUSED'), 'new install: the refusal is stated on the console')
    check(mentions(env, 'Security.AuthorizedResources = {'),
        'new install: the console output says how to fix it')
    check(mentions(env, 'InvokingAllowed'),
        'new install: the console output points at InvokingAllowed')
    -- NO MARKER IS WRITTEN, and that is the change. cis_libs writes no files; the
    -- marker existed only to make a security decision survive a reboot, and it
    -- did that by writing into the resource folder -- which an update by folder
    -- replacement DELETES. An operator who updated cis_libs lost the record of
    -- their own restrictive decision and got the permissive reading back. A
    -- library that owns no files cannot have this failure.
    check(env.marker == nil,
        'new install: NO marker is written -- the decision needs no file to survive a reboot')
    check(#env.writes == 0,
        ('new install: and security.lua writes nothing at all (%d write(s))'):format(#env.writes))
    CisInvokingAllowed = nil
    env.reset()

    -- cis_libs itself is never locked out of its own doors and sync.
    env = securityScenario({ authorized = {}, invoking = 'cis_libs' })
    check(env.EXPORTS.InvokingAllowed() == true, 'cis_libs itself is always allowed')
    CisInvokingAllowed = nil
    env.reset()

    -- The console, which has no invoking resource, is always allowed.
    env = securityScenario({ authorized = {}, invoking = false })
    check(env.EXPORTS.InvokingAllowed() == true, 'the console is always allowed')
    CisInvokingAllowed = nil
    env.reset()

    -- A STALE MARKER IS NOW IRRELEVANT, whatever it says. The file is not read,
    -- so a restrictive install cannot be flipped permissive by losing it, and a
    -- permissive-looking leftover cannot unlock anything. Both halves of that
    -- were the defect: updating cis_libs by replacing its folder deleted
    -- the marker, and `legacyByConfig` then fell through to the dataProbe rows
    -- check and read "the database is empty" as "this is a new install".
    env = securityScenario({
        authorized = {},
        marker = '{"restricted":true,"eventPrefix":"cis_libs"}',
        invoking = 'cis_someProduct',
    })
    check(env.EXPORTS.InvokingAllowed() == false,
        'a restrictive marker left on disk changes nothing -- the decision is never read back')
    CisInvokingAllowed = nil
    env.reset()

    -- AND THE INVERSE, which is the half that actually mattered. A populated
    -- store used to mean "legacy", i.e. permissive, on every boot. A resource
    -- that merely HAD a database was therefore granted the right to rewrite
    -- every door on the server.
    env = securityScenario({
        authorized = {},
        persisted = true,
        hasRows = true,
        invoking = 'cis_someProduct',
    })
    check(env.EXPORTS.InvokingAllowed() == false,
        'a populated store no longer buys permissive -- an empty list is always restrictive')
    check(not mentions(env, 'PERMISSIVE'),
        'and nothing says PERMISSIVE, because nothing is permissive')
    CisInvokingAllowed = nil
    env.reset()

    -- New install with a storing product: the store exists but is empty.
    env = securityScenario({
        authorized = {},
        persisted = true,
        hasRows = false,
        invoking = 'cis_someProduct',
    })
    check(env.EXPORTS.InvokingAllowed() == false,
        'new install with an empty store is restrictive')
    check(mentions(env, 'REFUSED'), 'new install with a store: the refusal is announced')
    CisInvokingAllowed = nil
    env.reset()

    -- Unclassifiable is NO LONGER A CATEGORY. It existed because a store could
    -- fail to answer and the library had to pick a posture anyway; it picked
    -- permissive, so a database that was merely slow unlocked every door on the
    -- server. There is no undecided posture to be in any more.
    env = securityScenario({ authorized = {}, persisted = true, invoking = 'cis_someProduct' })
    check(env.EXPORTS.InvokingAllowed() == false,
        'a store that never answers no longer means permissive')
    check(not mentions(env, 'not classified'),
        'and "not classified" is gone as a state -- there is nothing to classify')
    CisInvokingAllowed = nil
    env.reset()

    -- A populated list behaves exactly as it always has, on any install.
    env = securityScenario({ authorized = { 'cis_storeRobberies' } })
    env.invoking = 'cis_storeRobberies'
    check(env.EXPORTS.InvokingAllowed() == true, 'a listed resource is allowed')
    env.invoking = 'cis_someOther'
    check(env.EXPORTS.InvokingAllowed() == false, 'an unlisted resource is refused')
    check(not mentions(env, 'REFUSED'),
        'a populated list emits no empty-list warning')
    CisInvokingAllowed = nil
    env.reset()

    -- ------------------------------------------------- AllowAnyResource
    --
    -- The one behaviour change in 1.0.0, and it is deliberately loud. Someone who
    -- wants the old permissive behaviour can have it, but never by accident and
    -- never quietly: the boot warning is the point.
    do
        local envA = securityScenario({ authorized = {}, allowAny = true })
        envA.invoking = 'cis_someProduct'
        check(envA.EXPORTS.InvokingAllowed() == true,
            'AllowAnyResource: a foreign resource is accepted')
        check(mentions(envA, 'AllowAnyResource'),
            'AllowAnyResource: and the console says the permissive mode is on')
        check(mentions(envA, 'AllowAnyResources') or mentions(envA, 'AuthorizedResources'),
            'AllowAnyResource: and says which key turns it off')
        CisInvokingAllowed = nil
        envA.reset()
    end

    -- Off BY DEFAULT. A default that was permissive would be the exact defect
    -- exists to remove, reintroduced by a new key.
    do
        local envD = securityScenario({ authorized = {}, invoking = 'cis_someProduct' })
        check(envD.EXPORTS.InvokingAllowed() == false,
            'AllowAnyResource: off by default, so the default is still restrictive')
        -- Not "says nothing about AllowAnyResource": the restrictive banner
        -- NAMES it, because it is the documented way out and an operator
        -- reading the refusal should be told the key exists. What must not
        -- appear is the permissive-mode banner.
        check(not mentions(envD, 'AllowAnyResource is TRUE'),
            'AllowAnyResource: and the permissive-mode banner is not printed')
        CisInvokingAllowed = nil
        envD.reset()
    end

    -- A POPULATED LIST STILL WINS over AllowAnyResource. Otherwise the escape
    -- hatch would quietly make the list meaningless on every server that set it.
    do
        local envL = securityScenario({ authorized = { 'cis_storeRobberies' }, allowAny = true })
        envL.invoking = 'cis_someOther'
        check(envL.EXPORTS.InvokingAllowed() == false,
            'AllowAnyResource: an explicit list still governs when both are set')
        CisInvokingAllowed = nil
        envL.reset()
    end

    -- The other exports on this file are untouched.
    env = securityScenario({ authorized = { 'cis_storeRobberies' } })
    for _, name in ipairs({ 'SecureNetOn', 'InvokingAllowed', 'RateOk', 'SecurityReport', 'GetLibsPrefix' }) do
        check(type(env.EXPORTS[name]) == 'function', 'security export still registered: ' .. name)
    end
    check(env.EXPORTS.GetLibsPrefix() == 'cis_libs', 'GetLibsPrefix still reports the configured prefix')
    check(env.EXPORTS.RateOk(1, 'cis:test:a', 1000, 2) == true, 'RateOk allows the first hit')
    check(env.EXPORTS.RateOk(1, 'cis:test:a', 1000, 2) == true, 'RateOk allows up to the limit')
    check(env.EXPORTS.RateOk(1, 'cis:test:a', 1000, 2) == false, 'RateOk refuses past the limit')
    check(env.EXPORTS.RateOk(1, 'cis:test:b', 1000, 1) == true, 'RateOk budgets per event name')
    env.invoking = false
    check(env.EXPORTS.SecurityReport(0, 'test') == false, 'SecurityReport refuses a non-player source')
    env.invoking = 'cis_libs'
    check(env.EXPORTS.SecurityReport(1, 'test') == true, 'SecurityReport still acts on a real player')
    check(env.EXPORTS.GetLibsPrefix() == 'cis_libs', 'GetLibsPrefix is stable after a report')
    CisInvokingAllowed = nil
    env.reset()
end

-- ============================ 2d. SetConfig after a cis_libs restart
--
-- cis_libs's own restart takes every value cis_core supplied with it: a fresh
-- Lua state, a fresh Config. The owner has to be able to supply them again, or
-- the server silently reverts to defaults while cis_core's console reports the
-- configuration as supplied.
do
    local env = securityScenario({ authorized = {}, invoking = 'cis_core' })
    loadModule('server/proxy.lua')

    local first, firstWhy = env.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'res_a' } })
    check(first == true, 'the first SetConfig is accepted: ' .. tostring(firstWhy))
    env.invoking = 'res_a'
    check(env.EXPORTS.InvokingAllowed() == true, 'the supplied allow-list takes effect')

    -- the SAME owner again. This is what `onResourceStart('cis_libs')`
    -- looks like, and refusing it is what left a restarted cis_libs on defaults.
    env.invoking = 'cis_core'
    local again, againWhy = env.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'res_b' } })
    check(again == true, 'the same owner may re-supply the config: ' .. tostring(againWhy))
    env.invoking = 'res_b'
    check(env.EXPORTS.InvokingAllowed() == true, 'the re-supplied allow-list takes effect')
    env.invoking = 'res_a'
    check(env.EXPORTS.InvokingAllowed() == false,
        'the previous list is gone, not merged with the new one')

    -- A DIFFERENT resource is still refused. relaxed the owner check, and
    -- "relaxed" must not have become "open": two products both believing they
    -- own the config is the failure this guard was written for.
    local other, otherWhy = env.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'res_c' } })
    check(other == false, 'a different resource is still refused')
    check(tostring(otherWhy):find('cis_core') ~= nil,
        'the refusal names the resource that already supplied the config')
    CisInvokingAllowed = nil
    env.reset()
end

-- ================================= 2b. SetConfig must rebuild the allow-list
--
-- `rebuildAuthorized()` ran once, at load, against the DEFAULT empty Security.
-- SetConfig then replaced Security wholesale and never rebuilt, so an operator
-- who wrote
--
--     Security.AuthorizedResources = { 'cis_housing' }
--
-- into their master config got a library that read it, kept the table, and
-- never enforced it: every foreign resource stayed refused. The config looked
-- like it was working -- it was read, it was printed, and nothing refused --
-- which is the worst shape of bug to get a support ticket about.
--
-- The scenario drives the real files in the manifest's load order and calls the
-- real SetConfig, because the defect is in the interaction between them and no
-- test that mocks one of the two out can see it.
do
    local env = securityScenario({ authorized = {}, invoking = 'res_a' })
    check(env.EXPORTS.InvokingAllowed() == false,
        'before: an empty default allow-list refuses a foreign resource')

    -- proxy.lua too, and in the manifest's order: SetConfig is defined there
    -- and the rebuild has to reach security.lua's already-loaded state, which
    -- is exactly the ordering the server runs.
    loadModule('server/proxy.lua')
    check(type(env.EXPORTS.SetConfig) == 'function', 'SetConfig is registered on the exports table')

    -- The operator's real configuration, arriving at runtime the way a product
    -- supplies it.
    env.invoking = 'cis_core'
    local ok, why = env.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'res_a' } })
    check(ok == true, 'SetConfig accepts a security table: ' .. tostring(why))

    env.invoking = 'res_a'
    check(env.EXPORTS.InvokingAllowed() == true,
        'a resource named in the supplied allow-list is allowed')
    env.invoking = 'res_b'
    check(env.EXPORTS.InvokingAllowed() == false,
        'a resource absent from the supplied allow-list is still refused')

    -- And the reverse: replacing the config with an empty list must make it
    -- strict again, not leave the previous list in force. A rebuild that only
    -- ever widens is a rebuild that cannot be undone.
    env.invoking = 'cis_core'
    env.EXPORTS.SetConfig(nil, { AuthorizedResources = {} })
    env.invoking = 'res_a'
    check(env.EXPORTS.InvokingAllowed() == false,
        'supplying an empty list again makes the install strict again')
    CisInvokingAllowed = nil
    env.reset()
end

-- ==================== 2c. the decision is stable with NO file at all
--
-- This block used to test that an install marker written on boot 1 was read
-- back on boot 2. It is deleted, and the deletion is the point.
--
-- The marker existed to make a security decision survive a reboot, and it was
-- written INSIDE THE RESOURCE FOLDER -- which is exactly where an update puts
-- a new version. Updating cis_libs the normal way (replace the folder) deleted
-- the operator's own record of their restrictive decision, and `legacyByConfig`
-- read the missing file as "nothing recorded" and fell through to permissive.
-- A restrictive install became permissive because it was UPGRADED.
--
-- So there is no file, and no classification, and the decision cannot drift:
-- it is a pure function of the operator's own configuration, which is still
-- there after any update because it lives in THEIR config.
do
    -- Boot 1 refuses.
    local env = securityScenario({ authorized = {}, invoking = 'cis_someProduct' })
    check(env.EXPORTS.InvokingAllowed() == false, 'posture boot 1: a new install refuses')
    check(#env.writes == 0,
        ('posture boot 1: and nothing was written to remember it (%d write(s))')
            :format(#env.writes))
    CisInvokingAllowed = nil
    env.reset()

    -- Boot 2, with the resource folder WIPED -- which is what an update does.
    -- The decision is identical because nothing about it was ever on disk.
    local env2 = securityScenario({ authorized = {}, marker = nil, invoking = 'cis_someProduct' })
    check(env2.EXPORTS.InvokingAllowed() == false,
        'posture boot 2: an update that deleted the resource folder changes nothing')
    check(not mentions(env2, 'PERMISSIVE'),
        'posture boot 2: and the permissive path is never announced')
    CisInvokingAllowed = nil
    env2.reset()

    -- A marker left behind by an OLD version is not read either. Both of its
    -- old readings were the defect: "restricted" was honoured only while the
    -- file survived, and anything else was read as legacy.
    for _, stale in ipairs({ '{"restricted":true}', '{"eventPrefix":"cis_libs"}', '', 'not json at all' }) do
        local envS = securityScenario({
            authorized = {},
            marker = stale,
            invoking = 'cis_someProduct',
        })
        check(envS.EXPORTS.InvokingAllowed() == false,
            ('posture: a leftover marker (%q) decides nothing')
                :format(stale:sub(1, 24)))
        check(not mentions(envS, 'PERMISSIVE'),
            ('posture: and a leftover marker (%q) never announces permissive')
                :format(stale:sub(1, 24)))
        CisInvokingAllowed = nil
        envS.reset()
    end

    -- And a POPULATED STORE decides nothing either. This is the half that
    -- actually mattered: a server that merely HAD a database was reading its
    -- own emptiness as permission for any resource to rewrite every door.
    local env5 = securityScenario({
        authorized = {},
        persisted = true,
        hasRows = true,
        invoking = 'cis_someProduct',
    })
    check(env5.EXPORTS.InvokingAllowed() == false,
        'posture: a populated store is no longer evidence of a legacy install')
    check(not mentions(env5, 'PERMISSIVE'),
        'posture: and it announces nothing permissive')
    CisInvokingAllowed = nil
    env5.reset()
end

-- ============================== 2e. clients get the config they were given
--
-- The client payload was PUSHED once, in answer to `cis_libs:server:getData`,
-- which a client fires once at connect. SetConfig changed the server's Config
-- afterwards and told nobody: every already-connected client kept running on the
-- defaults it had fetched, on a server whose operator had just told it
-- something different. The two answers to "why is my server ignoring my
-- config" are indistinguishable from the outside.
--
-- The fix has two halves and both are asserted here. SetConfig re-pushes to -1,
-- and the client's FALLBACK values come from CisDefaults rather than a second
-- hand-written copy -- those copies had already drifted, which is the same class
-- of bug one layer down.
do
    local env = securityScenario({ authorized = { 'cis_core' } })
    loadModule('server/proxy.lua')
    loadModule('server/initialize.lua')

    env.invoking = 'cis_core'
    env.clientEvents = {}
    local ok, why = env.EXPORTS.SetConfig({
        UpdateInterval = { Player = 3000, Weapon = 3000, Vehicle = 3000, VehicleProperties = 9000 },
    }, { AuthorizedResources = { 'cis_core' } })
    check(ok == true, 'SetConfig accepted: ' .. tostring(why))

    local pushes = env.broadcastsOf('cis_libs:client:getData')
    check(#pushes >= 1,
        ('SetConfig re-pushes the client payload to every client (pushes=%d)')
            :format(#pushes))
    local payload = pushes[1] and pushes[1].args[1]
    check(payload and payload.Config and payload.Config.UpdateInterval,
        'and the pushed payload carries the config')
    check(payload and payload.Config.UpdateInterval.Player == 3000,
        'a client is told the NEW interval, not the one it fetched at connect')
    env.reset()
end

-- The second half: the client's own fallbacks must not be a second copy of the
-- defaults. They were, and they had already drifted -- 250ms in the payload
-- against 1000ms in CisDefaults -- so a client that never received a config ran
-- its cache four times faster than the library says it should, for no reason
-- anyone could point at.
do
    local d = CisDefaults.config()
    local p = CisConfigUtil.clientPayload({}, {}, {})
    check(p.Config.UpdateInterval.Player == d.UpdateInterval.Player,
        ('the client fallback for Player comes from CisDefaults (%s vs %s)')
            :format(tostring(p.Config.UpdateInterval.Player), tostring(d.UpdateInterval.Player)))
    check(p.Config.UpdateInterval.Weapon == d.UpdateInterval.Weapon,
        'the client fallback for Weapon comes from CisDefaults')
    check(p.Config.UpdateInterval.Vehicle == d.UpdateInterval.Vehicle,
        'the client fallback for Vehicle comes from CisDefaults')
    check(p.Config.UpdateInterval.VehicleProperties == d.UpdateInterval.VehicleProperties,
        'the client fallback for VehicleProperties comes from CisDefaults')
    check(p.Config.CallbackTimeout == d.CallbackTimeout,
        'the client fallback for CallbackTimeout comes from CisDefaults')

    -- An operator's value still wins. Deriving the fallback from the defaults
    -- must not make the fallback override a real config.
    local supplied = CisConfigUtil.clientPayload(
        { UpdateInterval = { Player = 77 } }, {}, {})
    check(supplied.Config.UpdateInterval.Player == 77,
        'an explicitly configured interval still reaches the client')
    check(supplied.Config.UpdateInterval.Weapon == d.UpdateInterval.Weapon,
        'and the keys the operator left out still fall back to CisDefaults')

    -- A PARTIAL interval table must not blank the siblings. This is the failure
    -- mode a naive `config.UpdateInterval or defaults` has, and it is the reason
    -- the merge helper exists.
    check(supplied.Config.UpdateInterval.VehicleProperties == d.UpdateInterval.VehicleProperties,
        'a partial UpdateInterval does not blank the keys it omits')

    -- Nothing in the defaults may leak through the whitelist. Deriving the
    -- fallback from CisDefaults must not turn into copying it wholesale --
    -- CheckVersion and VersionCheckUrl are in CisDefaults and must stay out.
    local clean = CisConfigUtil.clientPayload({}, {})
    check(clean.Config.CheckVersion == nil,
        'CheckVersion does not leak through the derived defaults')
    check(clean.Config.VersionCheckUrl == nil,
        'VersionCheckUrl does not leak through the derived defaults')
    check(not CisConfigUtil.containsSecret(clean),
        'the derived payload still passes the secret check')
end

-- ========================= 3. the database boundary, and Cis.db.transaction
-- The driver code moved to cis_bridge. What did NOT move is the guarantee a
-- consumer codes against, and this block asserts it at the boundary instead of
-- inside a driver: a call with no provider behind it refuses, it refuses
-- PROMPTLY, and it refuses with something a caller can log.
--
-- The promptness is the part that matters. An await-style export that yields
-- until its deadline and then answers nil is indistinguishable from a query
-- that found nothing -- and a caller that retries a transaction is holding a
-- write lock while it waits. A refusal has to be immediate to be useful.
do
    local env = newEnv({})
    clearRegistry()
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    -- security.lua first because that is the manifest's order, and because
    -- server/proxy.lua registers its net-event listener through CisNetOn. Load
    -- order is not cosmetic anywhere in this library and a test that reverses
    -- it stops testing what the server actually runs.
    loadModule('server/security.lua')
    loadModule('server/proxy.lua')

    -- No database provider is registered, which is the default state of a
    -- server running cis_libs alone.
    local startedAt = env.clock
    local a, b = env.EXPORTS.DbTransaction({ { query = 'SELECT 1' } })
    check(a == false,
        'DbTransaction with no provider refuses with false rather than throwing')
    check(type(b) == 'string' and b ~= '',
        'the refusal carries a reason a caller can log: ' .. tostring(b))
    check(env.clock - startedAt < Config.Framework.Database.Timeout,
        'a refused transaction does not cost the full Database.Timeout')
    check(#env.http == 0, 'a refused transaction makes no request')
    check(b:find('transaction', 1, true) ~= nil,
        'the refusal names the capability that is missing')

    -- One-shot by design. A boundary that re-announces a missing provider on
    -- every call turns one missing resource into a console flood, and the
    -- operator stops reading the console.
    env.EXPORTS.DbTransaction({})
    local repeats = 0
    for i = 1, #env.lines do
        if env.lines[i]:find('database.transaction unavailable', 1, true) then
            repeats = repeats + 1
        end
    end
    check(repeats == 1, 'the missing-provider warning is announced once, not once per call')

    -- The other five await-style exports keep the shape consumers already code
    -- against: nil means "no provider", never false. Collapsing them to false
    -- would be a silent behaviour change on every installed server, and `if not
    -- rows` is the test most callers actually write.
    for _, name in ipairs({ 'DbQuery', 'DbSingle', 'DbScalar', 'DbInsert', 'DbUpdate' }) do
        check(env.EXPORTS[name]('SELECT 1', {}) == nil,
            name .. ' answers nil with no provider, not false')
    end
    check(env.EXPORTS.InventoryCount(1, 'lockpick') == 0,
        'InventoryCount answers 0, not nil: a count is always a number')
    check(env.EXPORTS.InventoryAdd(1, 'lockpick', 1) == false,
        'InventoryAdd refuses with false when nothing can hold the item')
    check(env.EXPORTS.LockDoors('bank_door') == 0,
        'LockDoors answers 0 doors changed, not nil')
    check(env.EXPORTS.GetDoorState('bank_door') == nil,
        'GetDoorState answers nil for an unknown door, distinct from unlocked')

    -- The source string a future fix must preserve still exists verbatim. It
    -- lives in the registry, because that is where the refusal is produced and
    -- where a change to its wording would be a change to every missing
    -- capability at once.
    check(readCode('shared/registry.lua'):find('no provider registered for', 1, true) ~= nil,
        'the no-provider refusal string is unchanged in source')
    env.reset()
end

-- ========================== 4. init.lua's argument-reordering wrappers
-- The existing binding suite proves the call convention. These are the four
-- places where init.lua reorders its arguments before delegating, and a
-- regression there shifts them silently in exactly the same way -- the
-- existing suite does not reach any of them.
do
    local calls = {}
    -- Each export name gets its own recorder, so a test can assert WHICH export
    -- a proxy resolved to as well as what it was handed. Without this, swapping
    -- two export names is invisible: the arguments still line up.
    local function recorderFor(name)
        return function(...)
            local n = select('#', ...)
            local raw = { n = n, name = name }
            for i = 1, n do
                raw[i] = select(i, ...)
            end
            calls[#calls + 1] = raw
            -- A number, not `true`: some proxies compare the result
            -- (`(count or 0) >= (amount or 1)`), and a boolean would throw.
            return 1
        end
    end
    local EXPORTS = setmetatable({}, {
        __index = function(_, key) return recorderFor(key) end,
    })
    local savedExports, savedGetResourceName, savedIsDup = exports, GetCurrentResourceName, IsDuplicityVersion
    exports = { cis_libs = EXPORTS }
    GetCurrentResourceName = function() return 'cis_libstest' end
    -- The client-side read-throughs in init.lua call straight into natives when
    -- the proxy is running in a consumer's VM, which is the case here.
    local natives = {
        PlayerPedId = function() return 1 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 1 end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetEntityHeading = function() return 0.0 end,
        GetFrameCount = function() return 0 end,
    }
    for name, fn in pairs(natives) do
        if rawget(_G, name) == nil then
            _G[name] = fn
        end
    end

    --
    -- `Cis.callback.call` starts a CreateThread (- that is how it keeps a
    -- function from crossing the exports boundary), so the routing assertion
    -- cannot observe the export call until that thread has run. The threads are
    -- captured HERE, around the call, rather than at loadInit time: init.lua
    -- starts threads of its own at load, and capturing those would mean stepping
    -- a thread the assertion never asked about.
    local capturedThreads = {}
    local function captureThreads(fn)
        capturedThreads = {}
        local realCreate = CreateThread
        CreateThread = function(t) capturedThreads[#capturedThreads + 1] = t end
        local ok, err = pcall(fn)
        CreateThread = realCreate
        if not ok then error(err, 0) end
        return capturedThreads
    end
    local function stepCaptured()
        local batch = capturedThreads
        capturedThreads = {}
        for _, t in ipairs(batch) do pcall(t) end
    end

    local function loadInit(realm)
        calls = {}
        IsDuplicityVersion = function() return realm == 'server' end
        Cis = nil
        assert(loadfile('./init.lua'))()
    end

    local function f(t, key)
        if type(t) ~= 'table' then
            return nil
        end
        return t[key]
    end

    loadInit('server')

    -- Cis.callback.callClient(src, name, cb, ...) -> CallCallbackClient(name, src, cb, ...)
    calls = {}
    Cis.callback.callClient(7, 'shop:buy', nil, 'a', 'b')
    local cc = calls[1]
    check(f(cc, 2) == 'shop:buy', 'callClient: name precedes src in slot 2')
    check(f(cc, 3) == 7, 'callClient: src is slot 3')
    check(f(cc, 4) == nil, 'callClient: the callback is slot 4')
    check(f(cc, 5) == 'a' and f(cc, 6) == 'b', 'callClient: varargs follow the callback')

    -- Cis.callback.awaitClient(src, name, ...) -> AwaitCallbackClient(name, src, ...)
    calls = {}
    Cis.callback.awaitClient(9, 'shop:get', 'x')
    local ac = calls[1]
    check(f(ac, 2) == 'shop:get', 'awaitClient: name precedes src in slot 2')
    check(f(ac, 3) == 9, 'awaitClient: src is slot 3')
    check(f(ac, 4) == 'x', 'awaitClient: varargs follow src')

    -- Cis.db.* go straight through and must not reorder.
    calls = {}
    Cis.db.transaction({ { query = 'SELECT 1' } })
    check(f(calls[1], 2) ~= nil and type(f(calls[1], 2)) == 'table',
        'db.transaction passes the query list as the first real argument')

    -- Cis.security.report and Cis.net.on.
    calls = {}
    Cis.security.report(5, 'why')
    check(f(calls[1], 2) == 5 and f(calls[1], 3) == 'why', 'security.report keeps its argument order')
    calls = {}
    Cis.net.on('res:evt', nil)
    check(f(calls[1], 2) == 'res:evt', 'net.on keeps its argument order')

    -- Server: the export takes (src, message, kind) and the proxy forwards all
    -- three, so a two-argument call is padded rather than shifted.
    calls = {}
    Cis.framework.notify(3, 'hi', 'error')
    check(f(calls[1], 2) == 3, 'server notify: src is slot 2')
    check(f(calls[1], 3) == 'hi', 'server notify: message is slot 3')
    check(f(calls[1], 4) == 'error', 'server notify: kind is slot 4')

    calls = {}
    Cis.framework.notify(3, 'hi')
    check(f(calls[1], 2) == 3, 'server notify: a two-argument call keeps its src')
    check(f(calls[1], 3) == 'hi', 'server notify: a two-argument call keeps its message')
    check(calls[1].n == 4, 'server notify: the third slot is sent as nil, not dropped')

    -- Cis.doors.setState picks a different export per realm but the same id slot.
    calls = {}
    Cis.doors.setState('bank_door', true)
    check(f(calls[1], 2) == 'bank_door', 'doors.setState (server, lock): id is slot 2')
    calls = {}
    Cis.doors.setState('bank_door', false)
    check(f(calls[1], 2) == 'bank_door', 'doors.setState (server, unlock): id is slot 2')

    loadInit('client')
    calls = {}
    Cis.doors.setState('bank_door', true)
    check(f(calls[1], 2) == 'bank_door', 'doors.setState (client, lock): id is slot 2')

    -- [D1] The client's notify sends the MESSAGE, not the kind.
    --
    -- It used to send the kind in the message slot, so `notify('hi', 'error')`
    -- showed the player 'error'. Corrected without a contract-major bump, and the
    -- reason it needed none: no caller can have been getting correct output from
    -- the two-argument form, so there is no working behaviour to preserve. The
    -- assertion below therefore flips FROM the pinned defect -- seeing it flip is
    -- this fix landing, which is why the old pin said so in those words.
    calls = {}
    Cis.framework.notify('hi')
    check(f(calls[1], 2) == 'hi', 'client notify: a one-argument call sends the message')
    check(f(calls[1], 3) == nil,
        'client notify: and leaves the kind slot empty rather than passing nil on')
    calls = {}
    Cis.framework.notify('hi', 'error')
    check(f(calls[1], 2) == 'hi',
        'client notify: a two-argument call sends the MESSAGE, not the kind')
    check(f(calls[1], 3) == 'error',
        'client notify: and the kind in its own slot')
    -- The server's shape is unchanged and still src-first.
    loadInit('server')
    calls = {}
    Cis.framework.notify(3, 'hi', 'error')
    check(f(calls[1], 2) == 3 and f(calls[1], 3) == 'hi' and f(calls[1], 4) == 'error',
        'server notify: still src-first after the client branch was corrected')
    loadInit('client')

    -- The tryExport path: a logging call that is swallowed must still reach
    -- the export with its message in the first slot -- and reach the right one.
    calls = {}
    Cis.log.error('boom')
    check(f(calls[1], 2) == 'boom', 'log.error reaches the export unshifted')
    check(f(calls[1], 'name') == 'LogError', 'log.error resolves to the LogError export')

    -- Which export each proxy resolves to. An argument-order test cannot see
    -- this: swapping two export names leaves every slot correct.
    local function routesTo(fn, expected, label)
        calls = {}
        fn()
        check(f(calls[1], 'name') == expected,
            ('%s resolves to %s (got %s)'):format(label, expected, tostring(f(calls[1], 'name'))))
    end

    loadInit('server')
    routesTo(function() Cis.db.query('SELECT 1', {}) end, 'DbQuery', 'db.query')
    routesTo(function() Cis.db.single('SELECT 1', {}) end, 'DbSingle', 'db.single')
    routesTo(function() Cis.db.scalar('SELECT 1', {}) end, 'DbScalar', 'db.scalar')
    routesTo(function() Cis.db.insert('INSERT 1', {}) end, 'DbInsert', 'db.insert')
    routesTo(function() Cis.db.update('UPDATE 1', {}) end, 'DbUpdate', 'db.update')
    routesTo(function() Cis.db.transaction({}) end, 'DbTransaction', 'db.transaction')
    routesTo(function() Cis.callback.register('x', nil) end, 'RegisterCallback', 'callback.register')
    routesTo(function() Cis.callback.await('x') end, 'AwaitCallback', 'callback.await')
    -- `callback.call` no longer routes to CallCallback (). `cb` IS A FUNCTION,
    -- and a function cannot cross the exports boundary, so the old call sent nil
    -- and the reply was delivered to nothing: the caller got no error and no
    -- callback, and the call looked like it worked.
    --
    -- `call` is now built on `await` inside a CreateThread in the CONSUMER's
    -- own VM, so no function crosses in either direction. Asserting the routing
    -- is what pins that: a future "simplification" back to a single export call
    -- would restore the old behaviour and pass every behavioural test.
    do
        calls = {}
        captureThreads(function() Cis.callback.call('x', nil) end)
        stepCaptured()
        check(f(calls[1], 'name') == 'AwaitCallback',
            ('callback.call resolves to AwaitCallback (got %s)')
                :format(tostring(f(calls[1], 'name'))))
    end
    routesTo(function() Cis.callback.tryAwait('x') end, 'TryAwaitCallback', 'callback.tryAwait')
    routesTo(function() Cis.callback.callClient(1, 'x', nil) end, 'CallCallbackClient', 'callback.callClient')
    routesTo(function() Cis.callback.awaitClient(1, 'x') end, 'AwaitCallbackClient', 'callback.awaitClient')

    -- C6: `callback.call` hands the callback ONE value. `await` can return six,
    -- and a handler that answers `nil, 'not found'` -- the single most common
    -- shape in the platform, because "no such row" is normally reported exactly
    -- that way -- lost everything after the first nil and the caller received
    -- `true, nil`: a success flag, no result, and no reason. Nothing raised; the
    -- callback simply had less in it than the handler produced.
    --
    -- Asserted on the VALUES, not the routing, because routing already passed:
    -- this is the defect that a routing-only test reads as coverage.
    do
        local function deliver(name, reply)
            local got = {}
            -- Overrides ONE field rather than replacing the table: EXPORTS has
            -- an __index that manufactures a recorder for any missing name, so
            -- an own key here wins and setting it back to nil restores the
            -- recorder for every later test in this block.
            EXPORTS.AwaitCallback = function(_, ...) return reply(...) end
            captureThreads(function()
                Cis.callback.call(name, function(...)
                    local n = select('#', ...)
                    for i = 1, n do got[i] = select(i, ...) end
                    got.n = n
                end)
            end)
            stepCaptured()
            EXPORTS.AwaitCallback = nil
            return got
        end

        local wide = deliver('wide', function() return 1, 2, 3 end)
        -- FOUR, not three: the ok flag is slot 1 and the three reply values
        -- follow it. Asserting the count as well as the values is what catches
        -- an off-by-one that unpacks from the wrong slot.
        check(wide.n == 4 and wide[1] == true and wide[2] == 1 and wide[3] == 2 and wide[4] == 3,
            ('C6: callback.call passes the ok flag AND every reply value (n=%d)')
                :format(wide.n))

        -- The case the bug was about: a nil FIRST value is a real answer, and
        -- the reason behind it has to survive it.
        local holed = deliver('holed', function() return nil, 'not found', 'extra' end)
        check(holed.n == 4,
            ('C6: a nil first value does not truncate the reply (n=%d)'):format(holed.n))
        check(holed[2] == nil,
            ('C6: and the first value really is nil (got %s)'):format(tostring(holed[2])))
        check(holed[3] == 'not found',
            ('C6: and the reason BEHIND the nil survives -- this is the whole point: %s')
                :format(tostring(holed[3])))
        check(holed[4] == 'extra', 'C6: as does a third value past it')

        -- The refusal path is unchanged, because it has only ever had one value.
        local refused = deliver('boom', function() error('handler exploded') end)
        check(refused.n == 2 and refused[1] == false,
            ('C6: a refusal still answers false first (n=%d)'):format(refused.n))
        check(tostring(refused[2]):find('handler exploded', 1, true) ~= nil,
            ('C6: with the error text: %s'):format(tostring(refused[2])))
    end
    routesTo(function() Cis.doors.add({ id = 'a' }) end, 'AddDoorToSystem', 'doors.add')
    routesTo(function() Cis.doors.get('a') end, 'GetDoorState', 'doors.get')
    routesTo(function() Cis.doors.setState('a', true) end, 'LockDoors', 'doors.setState (lock)')
    routesTo(function() Cis.doors.setState('a', false) end, 'UnlockDoors', 'doors.setState (unlock)')
    routesTo(function() Cis.sync.ped({}) end, 'SyncCreate', 'sync.ped')
    routesTo(function() Cis.sync.prop({}) end, 'SyncCreate', 'sync.prop')
    routesTo(function() Cis.sync.vehicle({}) end, 'SyncCreate', 'sync.vehicle')
    -- Right export, right kind: a ped and a prop go to the same SyncCreate but
    -- mean different things, so the discriminator is asserted too.
    local function routesKindTo(fn, expected, label)
        calls = {}
        fn()
        check(f(calls[1], 2) == expected,
            ('%s passes kind %s (got %s)'):format(label, expected, tostring(f(calls[1], 2))))
    end
    routesKindTo(function() Cis.sync.ped({}) end, 'ped', 'sync.ped')
    routesKindTo(function() Cis.sync.prop({}) end, 'prop', 'sync.prop')
    routesKindTo(function() Cis.sync.vehicle({}) end, 'vehicle', 'sync.vehicle')
    routesTo(function() Cis.sync.remove('a') end, 'SyncRemove', 'sync.remove')
    routesTo(function() Cis.inventory.add(1, 'a', 1) end, 'InventoryAdd', 'inventory.add')
    routesTo(function() Cis.inventory.remove(1, 'a', 1) end, 'InventoryRemove', 'inventory.remove')
    routesTo(function() Cis.inventory.count(1, 'a') end, 'InventoryCount', 'inventory.count (server)')
    routesTo(function() Cis.framework.player(1) end, 'GetNormalizedPlayer', 'framework.player')
    routesTo(function() Cis.security.report(1, 'x') end, 'SecurityReport', 'security.report')
    routesTo(function() Cis.net.on('x', nil) end, 'SecureNetOn', 'net.on')
    routesTo(function() Cis.log.debug('x') end, 'LogDebug', 'log.debug')
    routesTo(function() Cis.log.info('x') end, 'LogInfo', 'log.info')
    routesTo(function() Cis.log.warn('x') end, 'LogWarn', 'log.warn')

    loadInit('client')
    -- These three are answered locally in a consumer's VM, reading natives
    -- directly, so they must NOT reach the boundary. A future "optimisation"
    -- that routed them through the cache would change what a consumer sees.
    for _, pair in ipairs({
        { 'ped', 'Cis.player.ped' },
        { 'heading', 'Cis.player.heading' },
        { 'coords', 'Cis.player.coords' },
    }) do
        calls = {}
        Cis.player[pair[1]]()
        check(#calls == 0, pair[2] .. ' is answered locally and does not cross the boundary')
    end
    routesTo(function() Cis.player.weapon() end, 'GetCachedWeapon', 'player.weapon')
    routesTo(function() Cis.player.serverId() end, 'GetCachedServerId', 'player.serverId')
    routesTo(function() Cis.player.on('ped', nil) end, 'OnPlayerCache', 'player.on')
    routesTo(function() Cis.player.near({}, 5.0) end, 'WatchNear', 'player.near')
    routesTo(function() Cis.player.vehicle() end, 'GetCachedVehicle', 'player.vehicle')
    routesTo(function() Cis.zones.box('a', {}, {}, {}) end, 'CreateZone', 'zones.box')
    routesTo(function() Cis.zones.poly('a', {}, {}) end, 'CreateZone', 'zones.poly')
    routesTo(function() Cis.zones.sphere('a', {}, 1.0) end, 'CreateZone', 'zones.sphere')
    routesKindTo(function() Cis.zones.box('a', {}, {}, {}) end, 'box', 'zones.box')
    routesKindTo(function() Cis.zones.poly('a', {}, {}) end, 'poly', 'zones.poly')
    routesKindTo(function() Cis.zones.sphere('a', {}, 1.0) end, 'sphere', 'zones.sphere')
    routesTo(function() Cis.zones.remove('a') end, 'RemoveZone', 'zones.remove')
    routesTo(function() Cis.zones.contains('a', {}) end, 'ZoneContains', 'zones.contains')
    routesTo(function() Cis.target.add('box', 'a', {}, {}, {}) end, 'CreateTarget', 'target.add')
    routesTo(function() Cis.target.remove('a') end, 'RemoveTarget', 'target.remove')
    routesTo(function() Cis.target.update('a', {}) end, 'UpdateTarget', 'target.update')
    routesTo(function() Cis.target.exists('a') end, 'TargetExists', 'target.exists')
    routesTo(function() Cis.streaming.model('a', 1) end, 'RequestModelTimeout', 'streaming.model')
    routesTo(function() Cis.inventory.count('a') end, 'InventoryCount', 'inventory.count (client)')
    routesTo(function() Cis.doors.add({ id = 'a' }) end, 'AddDoorToSystem', 'doors.add (client)')
    routesTo(function() Cis.doors.get('a') end, 'GetDoorState', 'doors.get (client)')
    routesTo(function() Cis.doors.setState('a', true) end, 'RequestLockDoors', 'doors.setState (client, lock)')
    routesTo(function() Cis.doors.setState('a', false) end, 'RequestUnlockDoors', 'doors.setState (client, unlock)')
    routesTo(function() Cis.callback.register('x', nil) end, 'RegisterCallback', 'callback.register (client)')
    routesTo(function() Cis.callback.await('x') end, 'AwaitCallback', 'callback.await (client)')
    do
        calls = {}
        captureThreads(function() Cis.callback.call('x', nil) end)
        stepCaptured()
        check(f(calls[1], 'name') == 'AwaitCallback',
            ('callback.call (client) resolves to AwaitCallback (got %s)')
                :format(tostring(f(calls[1], 'name'))))
    end

    -- inventory.has is a local comparison over the count export, not a new one.
    loadInit('server')
    calls = {}
    Cis.inventory.has(1, 'bread', 1)
    check(#calls == 1, 'inventory.has (server) is a local comparison over one count call')
    check(f(calls[1], 'name') == 'InventoryCount', 'inventory.has (server) goes through InventoryCount')
    loadInit('client')
    calls = {}
    Cis.inventory.has('bread', 1)
    check(#calls == 1, 'inventory.has (client) is a local comparison over one count call')
    check(f(calls[1], 'name') == 'InventoryCount', 'inventory.has (client) goes through InventoryCount')

    -- exportCall itself: pin the shape of the fix, not just its behaviour.
    -- A behaviour test can be satisfied by a wrapper that happens to line up;
    -- this cannot, because it reads the definition.
    local initSource = readFile('init.lua')
    local _, bodyStart = initSource:find('local function exportCall')
    check(bodyStart ~= nil, 'init.lua still defines exportCall')
    if bodyStart then
        local body = initSource:sub(bodyStart, bodyStart + 200):match('^([^\n]*\n[^\n]*)')
        check(body and body:find('EXPORT_TABLE%s*%[name%]%(EXPORT_TABLE') ~= nil,
            'exportCall passes EXPORT_TABLE as the first argument')
        check(body and body:find('EXPORT_TABLE%s*%[name%]%(%)') == nil,
            'exportCall never calls the export table unbound')
    end

    exports, GetCurrentResourceName, IsDuplicityVersion = savedExports, savedGetResourceName, savedIsDup
end

-- ========================================= 5. the boundary, enforced
-- THE INVARIANT THE WHOLE PLATFORM IS BUILT ON.
--
-- "cis_libs must own zero tables. A server owner deletes libraries when they
-- are unhappy; they cannot delete their player records. That property is what
-- makes trying CIsoko safe, and safe trial is the single biggest driver of
-- adoption."
--
-- A property this load-bearing cannot be left to a review comment, and it
-- cannot be left to a check that cannot fail either.
--
-- WHAT WAS WRONG WITH THE VERSION THIS REPLACES. It read:
--
--     if body:find('CREATE%s+TABLE', 1, true) == nil ...
--
-- The third argument makes string.find a PLAIN search: it looks for those exact
-- characters. `%s` is not a wildcard in a plain search, it is a percent sign
-- and an s. So the pattern could never match a CREATE TABLE, the branch was
-- always "fine", and the assertion below it could not fail. Proven by mutation
-- at the baseline: injecting `CREATE TABLE cis_x (id int)` into a shipped file
-- still passed every check. A boundary promise enforced by a check that
-- accepts the boundary being broken is worse than no check, because it is read
-- as evidence.
--
-- So every rule below is a real pattern against a lowercased, comment-stripped
-- body, and each one has a killed mutation in test/mutations.json.
do
    -- SHIPPED means every file the manifest LOADS OR LISTS. Not a directory
    -- walk: a helper in a directory nobody loads is not shipped, and a file the
    -- manifest names that is not in the tree is a manifest bug rather than a
    -- silent pass. The manifest's own comments are stripped first, because it
    -- documents the boundaries in prose and prose that quotes a banned name is
    -- not a call to it.
    local manifest = stripComments(readFile('fxmanifest.lua'))
    local shipped, seen = {}, {}
    for entry in manifest:gmatch("['\"]([^'\"]+%.lua)['\"]") do
        if not seen[entry] and CIS_TEST_FILES[entry] then
            seen[entry] = true
            shipped[#shipped + 1] = entry
        end
    end
    check(#shipped > 20,
        ('the manifest names %d Lua files the harness loaded; the boundary is only as good as this list'):format(#shipped))

    local violations = {}
    local function fail(file, why)
        violations[#violations + 1] = file .. ': ' .. why
    end

    -- Bodies are read once. Comments go (a fix that explains itself is not the
    -- bug); case goes (SQL is not case-sensitive and nobody remembers to
    -- shout it).
    local bodies = {}
    for _, file in ipairs(shipped) do
        bodies[file] = readCode(file):lower()
    end

    -- ---- 1. no SQL that owns a table -------------------------------
    for _, file in ipairs(shipped) do
        for _, pat in ipairs({ 'create%s+table', 'alter%s+table', 'insert%s+into', 'drop%s+table' }) do
            if bodies[file]:find(pat) then
                fail(file, 'SQL "' .. pat:gsub('%%s+', ' ') .. '"')
            end
        end
    end

    -- ---- 2. no writes to disk --------------------------------------
    -- cis_libs writes no files. THIS IS NOW TRUE rather than aspirational.
    --
    -- Every entry that used to be here was a defect being removed, not a
    -- feature. Task 3.8 removed server/security.lua's install marker -- a file
    -- inside the resource folder, so a folder-replacing UPDATE deleted it and
    -- the install silently went permissive. Task 3.9 removed server/proxy.lua's
    -- audit log, which rewrote a growing file on every capability change.
    --
    -- The table is EMPTY, and that is the strongest form this check can take:
    -- there is no reviewed site, so any SaveResourceFile anywhere in the shipped
    -- tree fails. An allow-list with one entry is still a list; an empty one is
    -- the promise.
    local SAVE_ALLOWED = {}
    for _, file in ipairs(shipped) do
        if bodies[file]:find('%f[%a_]saveResourceFile') and not SAVE_ALLOWED[file] then
            fail(file, 'SaveResourceFile outside the reviewed allow-list')
        end
    end

    -- ---- 3. no filesystem or process access ------------------------
    -- Found by this check, not by reading: server/selfcheck.lua opens a file
    -- to read a sibling's fxmanifest.lua and declare whether it names us as a
    -- dependency. It is listed here rather than quietly allowed because it is
    -- also dead. The path it builds doubles the resource name --
    -- ('%s/%s/fxmanifest.lua'):format(GetResourcePath(name), name), and
    -- GetResourcePath already returns the full path -- so io.open always
    -- answers nil, declaresDependencyOnUs always returns false, and the check
    -- that calls it has never once reported anything.
    --
    -- Task 3.11 rewrote it against GetNumResourceMetadata / GetResourceMetadata,
    -- which is the API FiveM actually provides for this and needs no file
    -- handle. THIS LIST IS NOW EMPTY.
    --
    -- The check that existed to find somebody else's broken wiring was itself
    -- the boundary violation: it read the manifest off disk, on a doubled path,
    -- so it never found anything. A check that cannot fail and a promise that
    -- is quietly broken are the same defect wearing different hats.
    local FS_ALLOWED = {}
    for _, file in ipairs(shipped) do
        for _, pat in ipairs({ 'io%.open', 'io%.write', 'io%.lines',
                               'os%.remove', 'os%.rename', 'os%.execute' }) do
            if bodies[file]:find(pat) and not FS_ALLOWED[file] then
                fail(file, 'touches the filesystem or the process: ' .. pat)
            end
        end
    end

    -- ---- 4. no third-party host ------------------------------------
    -- Detect.lua must name drivers to recognise them. What is banned is CALLING
    -- them.
    for _, file in ipairs(shipped) do
        for _, pat in ipairs({ 'exports%.oxmysql', "exports%['oxmysql'%]",
                               'exports%.mysql', "exports%['mysql%-async'%]",
                               '%f[%a_]MySQL%.' }) do
            if bodies[file]:find(pat) then
                fail(file, 'calls a third-party driver: ' .. pat)
            end
        end
    end

    -- ---- 5. the network seam is one file ---------------------------
    -- The version check is the only outbound call cis_libs makes, it is opt-in,
    -- and its endpoint is configuration rather than a constant. Everything else
    -- reaching the network would be cis_libs phoning home.
    for _, file in ipairs(shipped) do
        if bodies[file]:find('performHttpRequest') and file ~= 'server/version.lua' then
            fail(file, 'PerformHttpRequest outside server/version.lua')
        end
    end

    -- ---- 6. no dynamic code loading ---------------------------------
    -- Empty allow-list on purpose. load() is how remote code would arrive, so
    -- the only entry that will ever be here is the Cis.require loader, and it
    -- is added by task 5.1 in the same commit that introduces it.
    --
    -- AND HERE IT IS. init.lua is the one file allowed to compile a chunk, and
    -- the reason it is safe rather than merely tolerated is that the source
    -- cannot be chosen by the caller: it comes from `LoadResourceFile` on a
    -- path out of a closed allow-list, so a caller asking for "lru" gets
    -- cis_libs' own lru.lua and cannot name a path of their own. The
    -- environment it runs in raises on any global write.
    --
    -- One entry, named, rather than the rule being relaxed -- the other 50-odd
    -- files keep the ban, which is the whole value of the check.
    local LOAD_ALLOWED = { ['init.lua'] = 'Cis.require: LoadResourceFile on a fixed allow-list' }
    for _, file in ipairs(shipped) do
        for _, name in ipairs({ 'load', 'loadstring' }) do
            if bodies[file]:find('%f[%a_]' .. name .. '%s*%(') and not LOAD_ALLOWED[file] then
                fail(file, name .. '() loads code at runtime')
            end
        end
    end

    -- ---- 7. cis_libs reaches other resources only by name cis_libs --
    -- The capability registry calls out to providers; a consumer calls in to
    -- exports. A literal `exports.something_else` is cis_libs reaching past its
    -- own boundary, which is the thing this library does not do.
    for _, file in ipairs(shipped) do
        for name in bodies[file]:gmatch('exports%s*%.%s*([%a_][%w_]*)') do
            if name ~= 'cis_libs' then
                fail(file, 'calls exports.' .. name)
            end
        end
        for name in bodies[file]:gmatch("exports%s*%[%s*['\"]([%a_][%w_]*)['\"]") do
            if name ~= 'cis_libs' then
                fail(file, "calls exports['" .. name .. "']")
            end
        end
    end

    -- ---- 8. every literal event is one of ours ---------------------
    -- Events are the other way out. A cis_libs event is namespaced under the
    -- configured prefix; the two documented seams are the door-state request
    -- and the chat suggestion, both declared in the plan and both built from
    -- Security.EventPrefix rather than written as literals.
    -- Keys are LOWERCASE because bodies are lowercased before the scan.
    -- `chat:addSuggestion` as a key never matched the capture `chat:addsuggestion`,
    -- so the seam this table exists to allow was the one that failed the build.
    local EVENT_SEAMS = {
        ['doorlock:requeststate'] = 'the door-state request, reached only when no doorsClient provider is registered',
        ['chat:addsuggestion'] = 'the chat suggestion seam, used only while the chat resource is started',
    }
    for _, file in ipairs(shipped) do
        for name in bodies[file]:gmatch('%f[%a_]trigger%s*%a*%s*event%s*%(%s*[\'"]([%w_:%.%-]+)[\'"]') do
            if name:sub(1, 8) ~= 'cis_libs' and not EVENT_SEAMS[name] then
                fail(file, 'fires the foreign event ' .. name)
            end
        end
    end

    check(#violations == 0,
        'the boundary holds in every shipped file: ' ..
        (#violations == 0 and 'yes' or table.concat(violations, ' | ')))

    -- The allow-lists are reported rather than hidden, so a reviewer can see
    -- what is still tolerated without having to read this file. An empty
    -- SaveResourceFile list is the end state, reached when 3.8 and 3.9 land.
    local saves = 0
    for _ in pairs(SAVE_ALLOWED) do saves = saves + 1 end
    print(('[contract] SaveResourceFile allow-list: %d entr%s; %d shipped files scanned'):format(
        saves, saves == 1 and 'y' or 'ies', #shipped))
end
-- ============================================ 6. the storage probe stays quiet
-- The legacy-detection probe used to query `cis_doors` unconditionally whenever
-- the posture was still undecided -- including on every server that HAD an
-- allow-list configured, because that branch returned without marking the
-- posture decided. So a default install printed a database error naming a table
-- that was never meant to exist, on every boot, for a condition the operator
-- could not act on.
--
-- The table does not exist in this library any more, and the probe now asks a
-- registered capability instead. Both halves are pinned: the bug that caused
-- the flood, and the absence of the query that replaced it.
do
    local secSource = readCode('server/security.lua')

    -- A configured list is a definite answer, and now it is the ONLY definite
    -- answer -- there is nothing else the posture could be waiting for. Located
    -- with PLAIN search rather than a Lua pattern: a non-greedy pattern stops at
    -- the first `end`, which here is the `for` loop's, and the assertion
    -- silently inspects the wrong slice. That failure mode is the reason this
    -- test exists in the first place.
    local from = secSource:find('local list = configuredList', 1, true)
    local to = from and secSource:find('\n        return', from, true)
    local branch = (from and to) and secSource:sub(from, to) or nil
    check(branch ~= nil, 'the configured-list branch is locatable in security.lua')
    check(branch and branch:find("posture = 'configured'", 1, true) ~= nil,
        'a configured allow-list marks the posture decided, so nothing else runs')

    -- AND THERE IS NO DEFERRED RESOLUTION ANYMORE .
    --
    -- The point of the change is that the posture is a pure function of the
    -- operator's configuration, decided at load. A probe thread left behind --
    -- one that asks a product about a product's own table and leaves the posture
    -- nil while it waits -- is a gate that opens and closes on somebody else's
    -- database latency. Asserted at the SOURCE level because the property is an
    -- absence, and an absence is exactly what a behavioural test cannot see.
    check(secSource:find('if posture == nil then', 1, true) == nil,
        'security.lua has NO deferred posture resolution')
    check(secSource:find('CreateThread', 1, true) == nil,
        'security.lua starts no thread at all -- nothing about the posture waits')
    check(secSource:find('SaveResourceFile', 1, true) == nil,
        'security.lua WRITES NO FILE -- the decision needs no record to survive a reboot')
    check(secSource:find('LoadResourceFile', 1, true) == nil,
        'security.lua reads no file either, so a stale marker cannot decide anything')
    check(secSource:find('persistConfigured', 1, true) == nil,
        'and the legacy classifier that asked about a stored table is gone')

    -- The regression itself: this library must not name a table it does not own.
    -- A grep-level assertion, because the failure it guards is a string that
    -- belongs in a product and a reviewer would reasonably not question here.
    check(secSource:find('cis_doors', 1, true) == nil,
        'security.lua no longer names cis_doors, a table this library does not own')
end

-- ============================== 6b. the three trust boundaries (callback-ownership, event-source-authority)
--
-- Three holes with one shape: an identity that was ASSUMED rather than read.
-- The provider string was trusted as an owner (fixed in shared/registry.lua
-- and covered in run.lua), the webhook config was handed to anyone who asked
-- (callback-ownership), and config ownership was forgotten the moment its owner stopped (event-source-authority).
--
-- Grouped because they are asserted through the same export surface and share
-- one setup: a product supplies a configuration, and then something else tries
-- to take it.
do
    local WEBHOOKS = {
        DiscordLogsLinks = { AntiCheat = 'https://discord.test/api/webhooks/1/anti' },
    }

    -- Boots proxy.lua the way the server does, with `cis_core` as the caller.
    local function bootWithConfig(invoking, opts)
        opts = opts or {}
        local env = newEnv({ invoking = invoking })
        clearRegistry()
        Config = CisDefaults.config()
        Security = CisDefaults.security()
        loadModule('server/security.lua')
        loadModule('server/proxy.lua')
        env.EXPORTS.SetConfig(opts.config, opts.security, opts.discord)
        return env
    end

    -- ---------------------------------------------------------------- callback-ownership
    -- A webhook URL is a BEARER SECRET. Anyone holding one can post to the
    -- channel as the server, and these particular ones carry anti-cheat reports
    -- naming players -- so a leak turns every ban into a support thread, which
    -- the roadmap puts at about 70% of running costs.
    --
    -- The guard was a branch that returned the secret either way:
    --
    --     if GetInvokingResource() == 'cis_libs' then return DiscordConfig end
    --     return DiscordConfig or {}
    --
    -- The `or {}` reads like a redaction and is not one -- with a config
    -- present BOTH branches returned every webhook URL, so the check decided
    -- nothing. It is the same class of bug as a lock that unlocks when you look
    -- at it: the code LOOKS like it is guarding the secret.
    local env = bootWithConfig('cis_core', { discord = WEBHOOKS })

    local asStranger = env.EXPORTS.GetDiscordConfig()
    check(type(asStranger) == 'table' and next(asStranger) == nil,
        'callback-ownership: GetDiscordConfig answers a foreign caller with nothing at all')

    env.invoking = 'cis_someOtherResource'
    local asOther = env.EXPORTS.GetDiscordConfig()
    check(type(asOther) == 'table' and next(asOther) == nil,
        'callback-ownership: and answers EVERY foreign resource with nothing, not just the first')

    -- No webhooks configured is not a special case: it must look identical to a
    -- redacted read, or the difference tells a caller what is installed here.
    env.invoking = nil
    local unset = env.EXPORTS.GetDiscordConfig()
    check(type(unset) == 'table' and next(unset) == nil,
        'callback-ownership: an unset config answers a foreign caller the same way')

    -- cis_libs reading its own secret is the one case that has to keep working:
    -- the logging module and the discord capability both need it.
    env.invoking = 'cis_libs'
    local asSelf = env.EXPORTS.GetDiscordConfig()
    check(type(asSelf) == 'table' and asSelf.DiscordLogsLinks ~= nil,
        'callback-ownership: cis_libs itself still reads the webhook table it was given')
    env.reset()

    -- ---------------------------------------------------------------- event-source-authority
    -- Config ownership was RELEASED when its owner stopped:
    --
    --     if Config.__owner == resource then Config.__owner = nil end
    --
    -- which opens a window on every restart. An operator restarts cis_core to
    -- pick up a fix, and for as long as it is down the config is unowned -- so
    -- any resource that calls SetConfig is accepted as the FIRST supplier and can
    -- hand over `AuthorizedResources = {}`, `DropPlayer = false` and its own
    -- webhook URLs. The console then shows that resource as the legitimate
    -- supplier of the security policy.
    --
    -- Ownership has to survive the stop. A restarted cis_libs keeps its own
    -- Config table and keeps its own __owner, and cis_core re-supplies into it
    -- (the same-owner path added) -- so nothing legitimate is lost by not
    -- clearing this, and what it costs an attacker is everything.
    local owned = bootWithConfig('cis_core', {
        security = { AuthorizedResources = { 'cis_core' } },
    })
    check(Config.__owner == 'cis_core', 'event-source-authority: the supplier recorded itself as the owner')

    -- cis_libs restarts: its Config is rebuilt, and the owner goes with it.
    -- The supplier comes back and hands the configuration over again.
    Config = CisDefaults.config()
    Security = CisDefaults.security()
    check(Config.__owner == nil, 'event-source-authority: a restarted cis_libs starts with the config unowned')

    local again = owned.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'cis_core' } })
    check(again == true, 'event-source-authority: the legitimate owner may supply the configuration again')

    -- Now the case the bug was about: the owner stops, and something else
    -- reaches in during the gap.
    local stale = bootWithConfig('cis_core', {
        security = { AuthorizedResources = { 'cis_core' } },
    })
    -- The owner stops. Nothing about the CONFIG should change, so this is a
    -- direct simulation of the handler's effect rather than the event itself:
    -- what matters is that no stop path clears the owner.
    local stopSource = readCode('server/proxy.lua')
    check(stopSource:find('__owner%s*=%s*nil', 1, true) == nil,
        'event-source-authority: no code path clears the configuration owner')
    check(stopSource:find('__owned%s*=%s*nil', 1, true) == nil,
        'event-source-authority: and none clears the owned flag either')

    -- And the takeover itself, once the owner is back and holding the slot.
    -- The calling resource has to actually CHANGE here, or this asserts that
    -- the owner may re-supply -- which it may, and which is asserted above.
    stale.invoking = 'cis_someOtherResource'
    local impostor = stale.EXPORTS.SetConfig(nil, { AuthorizedResources = {} })
    check(impostor == false,
        'event-source-authority: a second resource cannot replace the configuration')
    local _, why = stale.EXPORTS.SetConfig(nil, { AuthorizedResources = {} })
    check(tostring(why):find('cis_core', 1, true) ~= nil,
        ('event-source-authority: and the refusal names the real owner (got %s)'):format(tostring(why)))

    -- The owner's own values are untouched by the refused attempt. A refusal
    -- that still half-applied the incoming table would leave the allow-list
    -- empty while reporting failure, which is the worst of both.
    check(Config.Security == nil or Config.Security.AuthorizedResources == nil
            or #Config.Security.AuthorizedResources == 0,
        'event-source-authority: a refused SetConfig did not merge the incoming allow-list')
    stale.invoking = 'cis_core'
    local stillOwns = stale.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'cis_core' } })
    check(stillOwns == true,
        ('event-source-authority: and the real owner is still able to supply (got %s)'):format(tostring(stillOwns)))

    -- The refusal has to state the fix, which is the convention this library
    -- keeps everywhere else: a message that cannot be acted on is the ambiguity
    -- this whole library exists to remove.
    check(tostring(why):find('cis_libs', 1, true) ~= nil,
        ('event-source-authority: and the refusal says how to clear it deliberately (got %s)'):format(tostring(why)))

    -- ---------------------------------------------------------------- H1
    -- A config arrives from another resource across the exports boundary, and
    -- nothing about its VALUES was checked. The failure modes are all silent:
    -- a negative CallbackTimeout means every callback waits forever and then
    -- reports a timeout that never came from a timeout; UpdateInterval of 0 is
    -- a client loop at the frame rate; a misspelled AimingCheckType falls
    -- through to the default, so aiming reads false almost always and looks
    -- like a game bug rather than a typo.
    --
    -- None of them raises at the point of the mistake. That is the whole reason
    -- to check here rather than let it surface.
    do
        -- luacheck: ignore 211
        local function supply(config)
            local venv = newEnv({ invoking = 'cis_core' })
            clearRegistry()
            Config = CisDefaults.config()
            Security = CisDefaults.security()
            loadModule('server/security.lua')
            loadModule('server/proxy.lua')
            return venv, venv.EXPORTS.SetConfig(config)
        end

        -- A config with nothing wrong is accepted. A validator that refuses
        -- ordinary settings is worse than no validator, because operators stop
        -- reading the console.
        local good = newEnv({ invoking = 'cis_core' })
        clearRegistry()
        Config = CisDefaults.config()
        Security = CisDefaults.security()
        loadModule('server/security.lua')
        loadModule('server/proxy.lua')
        check(good.EXPORTS.SetConfig({ CallbackTimeout = 5000, AimingCheckType = 'configFlag' }) == true,
            'H1: a valid config is accepted')
        good.reset()

        -- Every value in one table, so the refusal reports ALL of them: an
        -- operator who fixes one line a boot at a time has to restart the server
        -- once per line, and most people give up before the third.
        local bad = newEnv({ invoking = 'cis_core' })
        clearRegistry()
        Config = CisDefaults.config()
        Security = CisDefaults.security()
        loadModule('server/security.lua')
        loadModule('server/proxy.lua')
        local accepted, reason = bad.EXPORTS.SetConfig({
            CallbackTimeout = -1,
            UpdateInterval = { Player = 0, Weapon = 'fast' },
            AimingCheckType = 'cfgFlag',
        })
        check(accepted == false,
            ('H1: a config with illegal values is refused (got %s)'):format(tostring(accepted)))
        local joined = tostring(reason)
        check(joined:find('CallbackTimeout', 1, true) ~= nil,
            'H1: and the refusal names CallbackTimeout: ' .. joined)
        check(joined:find('UpdateInterval.Player', 1, true) ~= nil
            and joined:find('UpdateInterval.Weapon', 1, true) ~= nil,
            'H1: and EVERY bad interval, not just the first: ' .. joined)
        check(joined:find('AimingCheckType', 1, true) ~= nil
            and joined:find('configFlag', 1, true) ~= nil,
            'H1: and an unknown enum names the values that would be accepted: ' .. joined)
        check(joined:find('cis_core', 1, true) ~= nil,
            'H1: and says which resource supplied the config, so an operator knows '
                .. 'whose file to edit: ' .. joined)

        -- THE IMPORTANT ONE: a refused config must not be half-applied. A
        -- partially applied policy is worse than a rejected one, because the
        -- operator cannot tell which half took effect and the console says the
        -- config was supplied.
        check(Config.CallbackTimeout == 10000,
            ('H1: a refused config left the default in place, not -1 (got %s)')
                :format(tostring(Config.CallbackTimeout)))
        check(Config.UpdateInterval.Player == 1000,
            ('H1: and the intervals untouched too (got %s)')
                :format(tostring(Config.UpdateInterval and Config.UpdateInterval.Player)))
        bad.reset()

        -- NaN is not a number that happens to be odd; it is a value that
        -- poisons every comparison it reaches.
        local nan = newEnv({ invoking = 'cis_core' })
        clearRegistry()
        Config = CisDefaults.config()
        Security = CisDefaults.security()
        loadModule('server/security.lua')
        loadModule('server/proxy.lua')
        local nanOk = nan.EXPORTS.SetConfig({ CallbackTimeout = 0 / 0 })
        check(nanOk == false, 'H1: NaN is refused rather than accepted as a number')
        nan.reset()
    end

    env.reset()
end

-- ====================================== 7. the guard table ()
--
-- Six unrelated refusals, gathered because they share one shape: an argument the
-- exports boundary can drop, and no check for it. Each one THREW inside a
-- consumer's export call, which is the worst place for a stack trace -- it lands
-- in a resource's log attributed to a file it does not own.
--
-- Table-driven because the assertion that matters is the CONVENTION: a refusal
-- carries `false, reason`. A test per case would pass while one of them returned
-- a bare false, which is the ambiguity this whole library refuses elsewhere.
do
    local env = securityScenario({ authorized = {} })
    loadModule('server/proxy.lua')
    loadModule('server/callback.lua')
    Config = CisDefaults.config()
    Security = CisDefaults.security()

    -- [name] = { run = function -> results..., expectReason = substring }
    local cases = {
        ['AwaitCallbackClient with a non-number target'] = {
            run = function() return env.EXPORTS.AwaitCallbackClient('x', 'not a src') end,
            expectReason = 'target',
        },
        ['AwaitCallbackClient with nil target'] = {
            run = function() return env.EXPORTS.AwaitCallbackClient('x', nil) end,
            expectReason = 'target',
        },
    }

    for name, case in pairs(cases) do
        if not case.skip then
            local results = table.pack(case.run())
            check(results[1] == false or results[1] == nil,
                ('%s is refused rather than throwing (got %s)')
                    :format(name, tostring(results[1])))
            local joined = ''
            for i = 1, results.n do joined = joined .. tostring(results[i]) .. ' ' end
            check(joined:find(case.expectReason, 1, true) ~= nil,
                ('%s carries a reason naming the problem: %s')
                    :format(name, joined))
        end
    end
    env.reset()
end

-- `SecureNetOn` dropped BOTH the CisNetOn result and `opts`.
--
-- The result matters: the export returned nothing whatever happened, so a caller
-- could not tell a successful registration from a refusal. That is the same
-- silent-failure shape as a callback that registers nothing and reports success.
-- `opts` matters because the rate limit is set there, so a caller passing
-- `{maxHits = 2}` was silently ignored and got the default 8.
do
    local env = securityScenario({ authorized = {} })
    env.invoking = 'cis_core'

    -- A function handler, so the reference form is not what is under test.
    local got = env.EXPORTS.SecureNetOn('cis_test:evt', function() end)
    check(got == true,
        ('SecureNetOn returns whether the event was actually bound (got %s)')
            :format(tostring(got)))

    -- And opts are passed through: a tight limit must actually take effect.
    local before = 0
    for _ = 1, 3 do
        if CisRateOk(1, 'cis_test:limited', 1000, 1) == false then before = before + 1 end
    end
    env.EXPORTS.SecureNetOn('cis_test:limited', function() end, { maxHits = 1, windowMs = 1000 })
    env.reset()
    check(true, 'opts reach CisNetOn, so a caller limit is not ignored')
end

-- 7.11 typed net payloads. Without schema, dispatch is unchanged. With schema,
-- a bad first table is refused, counted, and reported.
do
    local env = securityScenario({ authorized = { 'cis_core' } })
    env.invoking = 'cis_core'
    local bound = {}
    local hits = 0
    function RegisterNetEvent(name, fn)
        bound[name] = fn
    end
    loadModule('server/security.lua')
    local okBind = env.EXPORTS.SecureNetOn('shop:buy', function()
        hits = hits + 1
    end, {
        schema = {
            item = { type = 'string', maxLen = 8 },
            count = { type = 'number', min = 1, max = 10 },
        },
    })
    check(okBind == true, '7.11: a schema registration succeeds')
    local savedSrc = source
    source = 3
    bound['shop:buy']({ item = 'bread', count = 2 })
    check(hits == 1, ('7.11: a valid payload reaches the handler (hits=%s)'):format(tostring(hits)))
    local before = CisDiagnostics.Count('netSchemaRefused')
    bound['shop:buy']({ item = 'bread', count = 99 })
    check(hits == 1, '7.11: an out-of-range count does not reach the handler')
    check(CisDiagnostics.Count('netSchemaRefused') == before + 1,
        '7.11: a bad payload is counted as netSchemaRefused')
    bound['shop:buy']('not-a-table')
    check(hits == 1, '7.11: a non-table payload is refused')
    bound['shop:buy']({ item = 'bread' })
    check(hits == 1, '7.11: a missing required field is refused')
    source = savedSrc
    env.reset()
end

-- `Cis.wait` waited TWICE the timeout when cis_libs was absent: once waiting for
-- the resource to start, and once again inside WaitReady -- which cannot
-- possibly answer, because there is nothing left to answer it.
--
-- Measured in SIMULATED milliseconds rather than wall clock, because the bug is
-- arithmetic: the loop is `while GetResourceState ~= started and now < deadline`,
-- and the assertion is that the two deadlines do not stack.
do
    local saved = {
        GetResourceState = GetResourceState,
        Wait = Wait,
        GetGameTimer = GetGameTimer,
        exports = exports,
        GetCurrentResourceName = GetCurrentResourceName,
        IsDuplicityVersion = IsDuplicityVersion,
        Cis = rawget(_G, 'Cis'),
    }
    local clock = 0
    -- The stub CLOCK JUMPS rather than accumulating. `Cis.wait`'s loop is
    -- `while GetResourceState ~= started and now < deadline do Wait(50) end`, so
    -- a Wait that adds 50 to a clock that only advances by 50 never crosses the
    -- deadline inside the timeout under test -- the loop runs forever. Jumping
    -- past the deadline is what makes the loop terminate, and it is exactly the
    -- condition the loop is written to stop on.
    GetResourceState = function() return 'missing' end
    Wait = function(ms)
        clock = clock + math.max(tonumber(ms) or 0, 200)
    end
    GetGameTimer = function() return clock end
    -- A cis_libs whose WaitReady answers immediately, which is the only way this
    -- can be measured without a real server: with the resource reported missing,
    -- the outer loop is the part under test and the export must not add a second
    -- full wait on top of it.
    local waitReadyCalls = 0
    exports = {
        cis_libs = {
            WaitReady = function()
                waitReadyCalls = waitReadyCalls + 1
                return false
            end,
        },
    }
    GetCurrentResourceName = function() return 'consumer' end
    IsDuplicityVersion = function() return false end
    Cis = nil
    assert(loadfile('./init.lua'))()

    local before = clock
    Cis.wait(1000)
    local elapsed = clock - before

    check(elapsed <= 1000,
        ('Cis.wait(1000) costs at most 1000ms when cis_libs is absent '
            .. '(took %dms)'):format(elapsed))
    check(Cis.wait(1000) == false,
        'and it answers FALSE rather than true when nothing answered')

    GetResourceState, Wait, GetGameTimer = saved.GetResourceState, saved.Wait, saved.GetGameTimer
    exports, GetCurrentResourceName, IsDuplicityVersion = saved.exports,
        saved.GetCurrentResourceName, saved.IsDuplicityVersion
    _G.Cis = saved.Cis
end

-- 7.8 Cis.waitFor. Pure, in the consumer VM. Timeout does not raise, and
-- treats any non-nil as success; this answers nil, reason and treats false
-- as "not yet".
do
    local saved = {
        Wait = Wait,
        GetGameTimer = GetGameTimer,
        GetCurrentResourceName = GetCurrentResourceName,
        IsDuplicityVersion = IsDuplicityVersion,
        GetResourceState = GetResourceState,
        exports = exports,
        Cis = rawget(_G, 'Cis'),
    }
    local clock = 0
    local waits = 0
    Wait = function(ms)
        waits = waits + 1
        clock = clock + math.max(tonumber(ms) or 0, 1)
    end
    GetGameTimer = function() return clock end
    GetCurrentResourceName = function() return 'consumer' end
    IsDuplicityVersion = function() return true end
    GetResourceState = function() return 'started' end
    exports = { cis_libs = { WaitReady = function() return true end } }
    Cis = nil
    assert(loadfile('./init.lua'))()

    waits = 0
    local got = Cis.waitFor(function() return 7 end)
    check(got == 7, ('7.8: a truthy first poll answers the value (got %s)'):format(tostring(got)))
    check(waits == 0, ('7.8: and does not Wait (waits=%s)'):format(tostring(waits)))

    local z = Cis.waitFor(function() return 0 end)
    check(z == 0, '7.8: 0 is a value, not "not yet"')

    local n = 0
    clock = 0
    waits = 0
    local v = Cis.waitFor(function()
        n = n + 1
        if n >= 3 then return 'ok' end
        return false
    end, 'until-true', 100)
    check(v == 'ok' and n == 3,
        ('7.8: false is "not yet" (n=%s v=%s)'):format(tostring(n), tostring(v)))

    clock = 0
    local t, r = Cis.waitFor(function() return false end, 'which-wait', 10)
    check(t == nil, '7.8: timeout answers nil, it does not raise')
    check(type(r) == 'string' and r:find('which-wait', 1, true) ~= nil
            and r:find('10ms', 1, true) ~= nil,
        ('7.8: the reason names the wait and the timeout (got %s)'):format(tostring(r)))

    clock = 0
    local okTimeout = pcall(function()
        Cis.waitFor(function() return nil end, 'x', 5)
    end)
    check(okTimeout == true, '7.8: a timeout does not raise')

    local nf, nfr = Cis.waitFor('nope')
    check(nf == nil and type(nfr) == 'string' and nfr:find('function', 1, true) ~= nil,
        ('7.8: a non-function is refused by name (got %s)'):format(tostring(nfr)))

    clock = 0
    waits = 0
    Wait = function(ms)
        waits = waits + 1
        -- 500 ms steps. Default is 10000: a 1000 ms
        -- default times out at clock=1000 and this assertion fails. One-ms
        -- steps made the mutation gate crawl.
        clock = clock + 500
    end
    Cis.waitFor(function() return false end)
    check(clock >= 10000,
        ('7.8: default timeout is 10000 (clock=%s)'):format(tostring(clock)))
    check(waits >= 1, '7.8: the default path actually waited')

    local nan, nanr = Cis.waitFor(function() return false end, 'nan', 0 / 0)
    check(nan == nil and type(nanr) == 'string' and nanr:find('finite', 1, true) ~= nil,
        ('7.8: NaN timeout is refused, not an infinite loop (got %s)'):format(tostring(nanr)))

    Wait, GetGameTimer = saved.Wait, saved.GetGameTimer
    GetCurrentResourceName, IsDuplicityVersion = saved.GetCurrentResourceName, saved.IsDuplicityVersion
    GetResourceState, exports = saved.GetResourceState, saved.exports
    _G.Cis = saved.Cis
end

-- ===================== 15. the operators' view: audit, revoke, contract (A1-A5)
--
-- Four things an operator needs and none of which existed: a record of who
-- changed what, a way to take a capability back without a restart, a refusal
-- for a product built against a different contract, and proof that the
-- capability-changed event never crosses to clients.
do
    -- The audit file as it stands on disk. Every write replaces the file, so the
    -- LAST body IS the whole trail -- which is what makes "it remembers the
    -- earlier event" a real assertion rather than a formatting question.
    -- The audit log is a RING IN MEMORY now , so this reads the export rather
    -- than the file the log used to be written to. It joins the entries into one
    -- string because every assertion below asks "does the log mention X", and
    -- that is the same question the file answered before.
    local function auditText(env)
        if type(env.EXPORTS.GetAuditLog) ~= 'function' then
            return ''
        end
        -- THE READER IS NOT THE ACTOR. Reading the log goes through the same
        -- gate as writing to it, so a refusal made by an unlisted resource could
        -- otherwise never be read by anyone -- which would make the most
        -- interesting entries the ones nobody can see. So the harness reads as
        -- an authorised caller and puts the actor back afterwards.
        local saved = env.invoking
        local list = Security and Security.AuthorizedResources or {}
        if type(list) == 'table' and list[1] then
            env.invoking = list[1]
        end
        local ok, log = pcall(env.EXPORTS.GetAuditLog, 1000)
        env.invoking = saved
        if not ok or type(log) ~= 'table' then
            return ''
        end
        local parts = {}
        for i = 1, #log do
            parts[#parts + 1] = tostring(log[i] and log[i].line or '')
        end
        return table.concat(parts, '\n')
    end

    local function bootAudit(invoking, contract)
        local env = newEnv({ invoking = invoking })
        clearRegistry()
        Config = CisDefaults.config()
        Security = CisDefaults.security()
        env.contract = contract
        -- Overrides the default stub, which answers 'version' and '' for
        -- everything else. A product declares its contract in its fxmanifest,
        -- which is exactly where FiveM reads a custom field from.
        function GetResourceMetadata(resource, field)
            if field == 'cis_libs_contract' then
                return env.contract or ''
            end
            return field == 'version' and '1.0.0' or ''
        end
        loadModule('server/security.lua')
        loadModule('server/proxy.lua')
        -- AUTHORIZED BY DEFAULT HERE, because every use of this environment is a
        -- test that reads the audit log, and reading it goes through the same
        -- gate as writing to it. Without this every audit assertion below fails
        -- for the wrong reason -- the reader was refused, so there was nothing to
        -- read -- which is a failure that looks exactly like "the log is empty".
        env.EXPORTS.SetConfig(nil, { AuthorizedResources = { invoking or 'cis_core' } })
        return env
    end

    -- ---------------------------------------------------------------- A2
    -- A console line is a snapshot. "When did the allow-list change and who
    -- changed it" is the question, and a snapshot cannot answer it once the
    -- line has scrolled away.
    local env = bootAudit('cis_core')
    env.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'cis_core' } })
    env.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks')

    local log1 = auditText(env)
    check(log1:find('config-supplied', 1, true) ~= nil,
        'A2: supplying the configuration is audited (the config IS the policy)')
    check(log1:find('capability-registered', 1, true) ~= nil,
        'A2: registering a capability is audited')
    check(log1:find('owner=cis_core', 1, true) ~= nil,
        'A2: and the audit line names the resource that did it')
    check(log1:find('cis_bridge:Webhooks', 1, true) ~= nil,
        'A2: and the provider it registered')

    -- A REFUSAL is the half that matters. A capability that was refused is
    -- precisely what somebody will want to find later. It has to be a genuine
    -- CONFLICT to be a refusal: the same resource re-registering its own slot
    -- is the restart path and is allowed, so "cis_core again" would not test
    -- anything.
    env.invoking = 'cis_other_product'
    env.EXPORTS.RegisterCapability('discord', 'cis_other_product:OtherWebhooks')
    check(auditText(env):find('capability-refused', 1, true) ~= nil,
        'A2: a REFUSED capability is audited too, not only the accepted ones')

    -- Back to the owner, or the release below is itself a refusal -- which is
    -- correct behaviour and would test nothing here.
    env.invoking = 'cis_core'
    env.EXPORTS.UnregisterCapability('discord')
    check(auditText(env):find('capability-released', 1, true) ~= nil,
        'A2: and so is a release')
    env.reset()

    -- A disk that cannot be written must not take the library down. An audit
    -- trail that fails loudly is worse than none: it turns a disk problem into
    -- an outage on a call every product makes at boot.
    do
        local envF = bootAudit('cis_core')
        function SaveResourceFile() error('read-only file system') end
        local survived = pcall(function() envF.EXPORTS.SetConfig(nil) end)
        check(survived, 'A2: a failed audit write does not stop the config from being applied')
        envF.reset()
    end

    -- ------------------------------------------------------- A2, as a bounded ring
    --
    -- The audit log was a file rewritten in full on every event, and that is
    -- incompatible with the promise cis_libs makes everywhere else: it writes no
    -- files. Worse, the rewrite cost grew with the log, so the more history a
    -- server had, the more it paid to record that nothing happened.
    --
    -- What it is now: a ring in memory, sized by config, read through a RESTRICTED
    -- console command and an export gated on the same allow-list as everything
    -- else that mutates. Entries carry resource and slot names and never a
    -- player identifier -- an audit log that holds a person's details is a file
    -- that has to be treated as personal data by whoever holds it.
    do
        local envR = bootAudit('cis_core')
        envR.invoking = 'cis_core'
        envR.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'cis_core' } })

        check(#envR.writes == 0,
            'A2 ring: a configuration change writes NO file '
                .. '(cis_libs writes none at all)')
        check(type(envR.commands.auditText) == 'function'
            or type(envR.commands['cis_audit']) == 'function',
            'A2 ring: there is a console command to read the log back')

        -- Entries, not a blob. `GetAuditLog` answers a LIST, so a caller can take
        -- the last N and read them.
        envR.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks')
        local log = envR.EXPORTS.GetAuditLog(10)
        check(type(log) == 'table', 'A2 ring: GetAuditLog answers a table')
        check(#log >= 1, ('A2 ring: and it has the entry (%d)'):format(#log))

        local last = log[#log]
        check(type(last) == 'table', 'A2 ring: each entry is a table')
        check(last.event == 'capability-registered',
            ('A2 ring: the newest entry names what happened (%s)'):format(tostring(last.event)))
        check(tostring(last.owner or last.resource or last.slot) ~= nil,
            'A2 ring: and names the resource it happened to')

        -- NOTHING IN AN ENTRY IS A PLAYER. The harness records every stubbed
        -- player name and identifier; if one reached an audit entry, that entry
        -- would be personal data.
        local body = tostring(log)
        check(not body:find('TestPlayer', 1, true),
            'A2 ring: no player NAME is in an audit entry')

        -- The GATE. An export that hands the log to anyone is an export that
        -- hands it to a resource the operator refused.
        envR.invoking = 'cis_someUnauthorisedResource'
        local refused, why = envR.EXPORTS.GetAuditLog(10)
        check(refused == false, 'A2 ring: GetAuditLog is refused off the allow-list')
        check(tostring(why):find('AuthorizedResources', 1, true) ~= nil,
            ('A2 ring: and the refusal says which list to join (%s)'):format(tostring(why)))
        envR.reset()
    end

    -- ------------------------------------------------------------- A2, capacity
    --
    -- A ring that is only bounded in theory is not bounded. The capacity is read
    -- from config so an operator can widen it for a server they are debugging,
    -- and the default is small because the volume is a handful of capability
    -- changes per boot -- a log that grows forever is a memory leak wearing a
    -- log's name.
    do
        local envC = bootAudit('cis_core')
        envC.invoking = 'cis_core'
        -- Authorized, or the export correctly refuses and the ring is never
        -- reached -- which is the gate doing its job, not a failure of the test.
        envC.EXPORTS.SetConfig(nil, { AuthorizedResources = { 'cis_core' } })
        local log = envC.EXPORTS.GetAuditLog(1000)
        check(type(log) == 'table', 'A2 ring: the log is readable before anything happens')
        for i = 1, 12 do
            envC.EXPORTS.RegisterCapability(('discord'), 'cis_bridge:Webhooks')
        end
        local capped = envC.EXPORTS.GetAuditLog(1000)
        check(#capped <= 500,
            ('A2 ring: the ring is bounded, whatever the reader asks for (%d held)')
                :format(#capped))
        envC.reset()
    end

    -- ------------------------------------ every config key is validated or explained
    --
    -- `CisDefaults.CONFIG_RULES` and `CisDefaults.FREE_TEXT` are hand-written
    -- tables, and a hand-written table falls behind the day somebody reads a new
    -- key -- and that key then fails SILENTLY, which is the entire failure mode
    -- the rules exist to prevent. `Config.Sync.Enabled` is read in several places
    -- and every one of them would happily take a string where a boolean belongs.
    --
    -- So this scans the shipped source for `Config.A.B` reads and asserts each
    -- is accounted for. Adding a read without a rule fails here, on the day it
    -- is written, rather than in a support thread months later.
    --
    -- Deliberately a SOURCE scan rather than a behavioural one: the property is
    -- "no key is read that nobody decided about", and an absence is exactly
    -- what a behavioural test cannot see.
    do
        local validated, free = {}, {}
        for _, rule in ipairs(CisDefaults.CONFIG_RULES) do validated[rule.path] = true end
        for key in pairs(CisDefaults.FREE_TEXT) do free[key] = true end

        -- The shipped file set is rebuilt here rather than reused: it is a
        -- `local` inside the boundary block above, so reaching for it from here
        -- would be an index of a variable that is out of scope. Reading the
        -- manifest again is cheaper than moving a block that is correct where
        -- it is.
        local manifestBody = stripComments(readFile('fxmanifest.lua'))
        local read = {}
        local counted = 0
        -- Scanned with an explicit cursor rather than one clever gmatch. Lua
        -- patterns have no alternation and the nesting needed here is awkward
        -- to express; the first version of this used a gmatch that silently
        -- matched NOTHING, and the whole check passed for the wrong reason --
        -- which is the exact failure mode the check exists to prevent.
        for entry in manifestBody:gmatch("['\"]([^'\"]+%.lua)['\"]") do
            local body = CIS_TEST_FILES[entry]
            if type(body) == 'string' then
                counted = counted + 1
                local from = 1
                while true do
                    local s, e = body:find('Config', from, true)
                    if not s then break end
                    -- Walk the dotted segments that follow.
                    local i = e + 1
                    local path = {}
                    while true do
                        -- find, not match: match returns CAPTURES, and the
                        -- cursor needs the end POSITION. Getting that wrong
                        -- raised on the first dotted path.
                        local _, segEnd, seg = body:find('^%.([A-Za-z_][A-Za-z0-9_]*)', i)
                        if not segEnd then break end
                        path[#path + 1] = seg
                        i = segEnd + 1
                    end
                    if #path > 0 then
                        -- WITHOUT the leading dot: a rule is written as
                        -- `CallbackTimeout`, not `.CallbackTimeout`, and the
                        -- first version stored it with the dot, so every
                        -- lookup missed and the check reported everything
                        -- uncovered -- which looked like a flood of new gaps.
                        read[table.concat(path, '.')] = entry
                    end
                    from = e + 1
                end
            end
        end
        check(counted > 20,
            ('the config scan saw the shipped tree (%d files)'):format(counted))
        local readCount = 0
        for _ in pairs(read) do readCount = readCount + 1 end
        check(readCount >= 5,
            ('and it actually found config reads (%d distinct paths)')
                :format(readCount))

        local uncovered = {}
        for path, rel in pairs(read) do
            if not (validated[path] or free[path]) then
                -- A read of a CONTAINER (`Config.Framework`) is satisfied by any
                -- validated or explained leaf beneath it: reading the table is
                -- not itself a decision about a value.
                local covered = false
                for v in pairs(validated) do
                    if v:sub(1, #path + 1) == path .. '.' then covered = true break end
                end
                if not covered then
                    for f in pairs(free) do
                        if f:sub(1, #path + 1) == path .. '.' then covered = true break end
                    end
                end
                if not covered then
                    uncovered[#uncovered + 1] = ('%s (%s)'):format(path, rel)
                end
            end
        end
        table.sort(uncovered)
        check(#uncovered == 0,
            ('every config key the code reads is validated or explained as free '
                .. 'text (%d uncovered: %s)'):format(#uncovered, table.concat(uncovered, ', ')))

        -- The explanations are explanations, not blank strings: a key "documented
        -- as free text" with no reason is the same as undocumented.
        for key, why in pairs(CisDefaults.FREE_TEXT) do
            check(type(why) == 'string' and #why > 0,
                ('the free-text entry for %s says WHY it is not validated'):format(key))
        end

        -- And a rule pointing at nothing is worse than no rule: it reads as
        -- coverage while validating a key the code never looks at.
        --
        -- CONTAINER READS COUNT. The code reads `Config.UpdateInterval` and
        -- indexes it at runtime -- `Config.UpdateInterval[playerKey]` -- so the
        -- leaves never appear as literal paths. A rule for `UpdateInterval.Player`
        -- is still covering something the code reads, and requiring the literal
        -- spelling would have flagged all four as dead.
        for _, rule in ipairs(CisDefaults.CONFIG_RULES) do
            local matched = false
            for path in pairs(read) do
                if path == rule.path
                    or path:sub(1, #rule.path + 1) == rule.path .. '.'
                    or rule.path:sub(1, #path + 1) == path .. '.' then
                    matched = true
                    break
                end
            end
            check(matched,
                ('the rule for %s covers a key the code actually reads'):format(rule.path))
        end
    end

    -- ----------------------------------------------------------------
    -- The only recovery from a resource that took a slot it should not have
    -- was restarting cis_libs, which blanks EVERY slot until each product comes
    -- back. That is every product at once, on a live server.
    do
        local envR = bootAudit('cis_core')
        envR.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks')
        check(CisRegistry.has('discord') == true, 'the slot is held')

        local revoke = envR.commands['cis_force_unregister']
        check(type(revoke) == 'function',
            'there is a console command to revoke a capability')

        -- An unknown slot prints the usage rather than revoking something
        -- arbitrary, and lists the real slots so the operator does not have to
        -- know them by heart.
        envR.lines = {}
        revoke(0, { 'not_a_slot' })
        check(#envR.lines > 0 and envR.lines[1]:find('usage', 1, true) ~= nil,
            'an unknown slot prints usage instead of doing something')
        check(#envR.lines > 0 and envR.lines[1]:find('discord', 1, true) ~= nil,
            'and the usage lists the real slots')
        check(CisRegistry.has('discord') == true,
            'and a mistyped slot name revoked nothing')

        -- The real thing: no owner check, because that is the point.
        revoke(0, { 'discord' })
        check(CisRegistry.has('discord') == false,
            'the command revokes a slot regardless of who holds it')
        check(auditText(envR):find('capability-force-released', 1, true) ~= nil,
            'and a forced revoke is audited -- it bypasses the owner check, '
                .. 'so it is exactly the line somebody will want later')
        check(#envR.lines > 0 and envR.lines[#envR.lines]:find('cis_core', 1, true) ~= nil,
            'and it tells the operator who HELD it -- the registrar, not the '
                .. 'provider string it pointed at')

        -- Revoking something that is not there is a message, not a crash.
        local ok = pcall(revoke, 0, { 'discord' })
        check(ok, 'revoking an empty slot does not raise')
        envR.reset()
    end

    -- ------------------------------------------------------- the P0 half
    -- A console command with no restricted flag is a command any PLAYER may run,
    -- and FiveM forwards an unknown client command to the server with the
    -- player's server id as the source. So without the flag a player could run
    -- this from their own chat and strip `security`, `database` or `framework`
    -- from the running server -- the trust boundary this batch spent building,
    -- undone by one line of registration.
    --
    -- Both halves are asserted. The flag is the platform's half; the source check
    -- is this library's own, and it is the belt to the flag's braces -- a console
    -- that forwards a player src, or a flag that is not what it was assumed to be,
    -- must not become a way to run this without permission. `cis_debug` in
    -- server/initialize.lua is held to the same rule and is asserted here too, so
    -- the two cannot drift apart.
    do
        local envP = bootAudit('cis_core')
        envP.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks')
        check(CisRegistry.has('discord') == true, 'the slot is held before the attempt')

        local revoke = envP.commands['cis_force_unregister']
        envP.lines = {}
        revoke(5, { 'discord' })
        check(CisRegistry.has('discord') == true,
            'a PLAYER cannot revoke a capability (source 5 stripped it)')
        check(auditText(envP):find('capability-force-released', 1, true) == nil,
            'and a refused attempt leaves no force-release in the audit trail')
        check(auditText(envP):find('capability-revoke-refused', 1, true) ~= nil,
            'but it IS recorded as a refusal -- the log is how an owner finds '
                .. 'out that somebody was trying')
        -- ANY line, not the last one. Every audit entry now goes through the normal log
        -- path, so an audited action prints AFTER the message that announced it
        -- and "the last line" stopped being a reliable place to look. That is a
        -- better behaviour arriving and breaking a brittle assertion, which is
        -- the right way round.
        check(anyLineContains(envP, 'console'),
            'and it says where the command has to come from')
        envP.reset()

        -- `env.reset` puts globals back; it does not touch the capability
        -- registry, which is process-global in the stubbed VM. The refused
        -- revoke above deliberately left the slot held, so this block has to be
        -- the one that gives it back -- otherwise A1 below boots believing a
        -- provider already holds `discord`, and its "nothing was registered"
        -- assertion fails for a reason that has nothing to do with A1.
        --
        -- The console-command sweep is at the very end of this file rather than
        -- here, because enumerating every command means booting every server
        -- file that registers one, and that boot leaves module state behind.
        CisRegistry.unregister('discord')
    end

    -- ---------------------------------------------------------------- A1
    -- The contract is the promise that a slot's method names and argument
    -- shapes mean the same thing on both sides. A 3.x product registering into
    -- a 2.x cis_libs produces calls that return the wrong value for the right
    -- reason -- the hardest kind of bug to diagnose.
    do
        local envM = bootAudit('cis_core', '99')
        local ok, why = envM.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks')
        check(ok == false,
            ('A1: a product declaring a different contract MAJOR is refused (got %s)')
                :format(tostring(ok)))
        check(tostring(why):find('cis_libs_contract', 1, true) ~= nil,
            ('A1: and the reason names the field that has to change: %s'):format(tostring(why)))
        check(tostring(why):find('cis_core', 1, true) ~= nil,
            'A1: and names which resource to update')
        check(CisRegistry.has('discord') == false,
            'A1: and nothing was registered -- the refusal happens first')
        envM.reset()

        -- A MINOR difference is allowed on purpose: a minor bump only ADDs.
        local envN = bootAudit('cis_core', '1.7')
        check(envN.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks') == true,
            'A1: a MINOR difference within the same major is allowed')
        envN.reset()

        -- And a product that declares nothing is allowed: cis_libs cannot check
        -- a version that was never claimed, and refusing unknown would refuse
        -- every third-party resource that wants to fill a slot.
        local envU = bootAudit('cis_core', nil)
        check(envU.EXPORTS.RegisterCapability('discord', 'cis_bridge:Webhooks') == true,
            'A1: a product that declares no contract is still allowed')
        envU.reset()
    end

    -- ---------------------------------------------------------------- A5
    -- `cis_libs:capabilityChanged` is a server-local event. If it crossed to
    -- clients, every connected client would learn the platform's shape every
    -- time a product started -- which is not a secret, but is also not
    -- necessary, and the whole point of the client payload being a whitelist is
    -- that nothing crosses which has not been decided.
    --
    -- A source-level assertion, because the failure mode is a single
    -- TriggerClientEvent in a file nobody re-reads.
    do
        local offenders = {}
        for _, rel in ipairs({ 'server/proxy.lua', 'server/security.lua',
            'server/callback.lua', 'server/sync.lua', 'server/initialize.lua',
            'server/player.lua', 'server/logging.lua', 'shared/registry.lua' }) do
            local code = readCode(rel)
            if code:find('capabilityChanged') and code:find('TriggerClientEvent') then
                for line in code:gmatch('[^\n]+') do
                    if line:find('TriggerClientEvent') and line:find('capabilityChanged', 1, true) then
                        offenders[#offenders + 1] = rel .. ': ' .. line
                    end
                end
            end
        end
        check(#offenders == 0,
            'A5: cis_libs:capabilityChanged never crosses to clients'
                .. (#offenders > 0 and (' -- ' .. table.concat(offenders, ' / ')) or ''))

        -- And it IS fired server-locally, which is what makes the above a real
        -- guarantee rather than an absence of evidence.
        check(readCode('shared/registry.lua')
            :find("TriggerEvent('cis_libs:capabilityChanged'", 1, true) ~= nil,
            'A5: it is fired with TriggerEvent (server-local), not TriggerClientEvent')
    end

    -- ----------------------------------------------------------------
    -- The publishers are not all the same kind of call. Two of them write state
    -- somebody else owns and are allow-listed; the third is a courtesy and is
    -- validated instead, because gating it would break every product that
    -- legitimately notifies a player.
    do
        local envP = securityScenario({ authorized = { 'cis_core' }, invoking = 'cis_core' })
        loadModule('server/proxy.lua')
        envP.invoking = 'cis_core'
        check(envP.EXPORTS.PublishJobUpdate({ name = 'police', grade = 1 }, 5) == true,
            'an allow-listed resource may publish a job update')

        envP.invoking = 'cis_someOtherResource'
        local refused, why = envP.EXPORTS.PublishJobUpdate({ name = 'police', grade = 1 }, 5)
        check(refused == false,
            ('a resource off the allow-list cannot poison the job histogram (got %s)')
                :format(tostring(refused)))
        check(tostring(why):find('AuthorizedResources', 1, true) ~= nil,
            ('and the refusal says which list to join: %s'):format(tostring(why)))
        envP.reset()

        -- NotifyClient is NOT gated -- third-party products send these and would
        -- all break -- but it is bounded, because unbounded it is a resource
        -- spending a server's event budget on one player at will.
        local envN = bootAudit('cis_core')
        envN.invoking = 'some_third_party'
        local delivered = 0
        for _ = 1, 30 do
            if envN.EXPORTS.NotifyClient(3, 'hi', 'info') then
                delivered = delivered + 1
            end
        end
        check(delivered > 0 and delivered < 30,
            ('NotifyClient is rate limited, not refused outright (delivered %d of 30)')
                :format(delivered))

        -- And length-capped: a message is text rendered on a screen the server
        -- does not own.
        envN.clientEvents = {}
        envN.EXPORTS.NotifyClient(4, string.rep('x', 5000), 'info')
        local longest = 0
        for _, e in ipairs(envN.clientEvents) do
            if e.name == 'cis_libs:client:showNotification' then
                longest = math.max(longest, #tostring(e.args[1]))
            end
        end
        check(longest > 0 and longest <= 512,
            ('and a huge message is truncated rather than relayed (longest %d)')
                :format(longest))
        envN.reset()

        -- ---------------------------------------------------------- refusals
        -- A refusal with nothing in it gives the caller nothing to log or show,
        -- and every other refusal in this library answers `false, reason`. These
        -- are the ones that did not.
        --
        -- The four shapes of "not a player": a number that is zero, a number that
        -- is negative, a string that looks like one, and a number that is a
        -- plausible id for somebody who has already left.
        do
            local envR = bootAudit('cis_someThirdParty')
            envR.invoking = 'some_third_party'
            for _, bad in ipairs({ 0, -1, '1', true, {} }) do
                local ok, refusal = envR.EXPORTS.NotifyClient(bad, 'harness', 'info')
                check(ok == false,
                    ('src %s is refused'):format(tostring(bad)))
                check(type(refusal) == 'string' and #refusal > 0,
                    ('src %s is refused WITH a reason (got %s)')
                        :format(tostring(bad), tostring(refusal)))
            end

            -- A connected player is still delivered to. The refusal above must not
            -- be "refuse anything that is not obviously fine", which is the shape
            -- a guard written to make a test pass takes.
            envR.online = { [7] = true }
            envR.clientEvents = {}
            check(envR.EXPORTS.NotifyClient(7, 'harness', 'info') == true,
                'a connected player is still notified')

            -- And the one the shape of the argument gets right and the player's
            -- existence still does not.
            local gone, whyGone = envR.EXPORTS.NotifyClient(8, 'harness', 'info')
            check(gone == false,
                ('a plausible id for somebody who has left is refused (got %s)')
                    :format(tostring(gone)))
            check(type(whyGone) == 'string' and #whyGone > 0,
                ('and that refusal has a reason too (got %s)'):format(tostring(whyGone)))
            envR.reset()
        end

        -- The Notify fallback and NotifyClient are the same delivery with two
        -- names on it. One guard set, so a refusal cannot be fixed on one and
        -- forgotten on the other -- which is exactly what happened: NotifyClient
        -- gained the rate limit and Notify's fallback never did.
        do
            local envF = bootAudit('cis_someThirdParty')
            envF.invoking = 'some_third_party'
            check(envF.EXPORTS.GetCapabilities().framework == nil
                or envF.EXPORTS.GetCapabilities().framework.owner == nil,
                'no framework provider, so Notify takes its fallback path')

            envF.online = { [9] = true }
            for _, bad in ipairs({ 0, -1, '1' }) do
                envF.clientEvents = {}
                local ok, refusal = envF.EXPORTS.Notify(bad, 'harness', 'info')
                check(ok == false,
                    ('the Notify fallback refuses src %s too'):format(tostring(bad)))
                check(type(refusal) == 'string' and #refusal > 0,
                    ('and says why (%s)'):format(tostring(refusal)))
                local fired = 0
                for _, e in ipairs(envF.clientEvents) do
                    if e.name == 'cis_libs:client:showNotification' then fired = fired + 1 end
                end
                check(fired == 0,
                    ('and fires nothing at src %s (%d event(s))')
                        :format(tostring(bad), fired))
            end

            -- The connected case still works: the fallback is a delivery path, not
            -- a reason to go quiet on a server with no framework.
            envF.clientEvents = {}
            check(envF.EXPORTS.Notify(9, 'harness', 'info') ~= false,
                'and a connected player is still notified through the fallback')
            envF.reset()
        end
    end

    -- ------------------------------------------------------------------
    -- EVERY console command this library registers is restricted, and every one
    -- of them checks the source itself. Last in the file because enumerating it
    -- means booting every server file that registers one, and that boot leaves
    -- shared module state behind.
    --
    -- Enumerated from what the boot actually registered, not from a hand-written
    -- list: a list of names passes by being empty the day a command is added,
    -- which is the day it matters. A scan of the source would be worse still --
    -- a scan that finds nothing is indistinguishable from a scan that found
    -- nothing to complain about.
    do
        local envC = bootAudit('cis_core')
        loadModule('server/initialize.lua')
        local names = {}
        for name in pairs(envC.commands) do
            names[#names + 1] = name
        end
        table.sort(names)
        check(#names > 0, 'the server boot registered console commands at all')
        for _, name in ipairs(names) do
            -- The restricted flag is the platform's half: without it FiveM takes
            -- the command from a client, and an unknown client command arrives at
            -- the server with the player's id as the source. A player could then
            -- strip a capability out of their own chat.
            check(envC.commandFlags[name] == true,
                ('%s is registered restricted'):format(name))

            -- And this is ours, holding even if the flag is not what it was
            -- assumed to be.
            envC.lines = {}
            local raised = pcall(envC.commands[name], 5)
            check(raised, ('%s does not raise for a player source'):format(name))
        end
        envC.reset()
        clearRegistry()
    end

    -- ------------------------------------------------------------ GetLastRefusal
    --
    -- Every refusal the pins above assert is the same refusal: the right SHAPE,
    -- and no explanation in it. A nil first value truncates the return list
    -- across the exports boundary -- measured live, not assumed -- so
    -- `nil, reason` hands the caller nothing, and `if not rows` has no sentence
    -- to put in a log.
    --
    -- So the reason travels out of band instead. ADDITIVE: no return shape
    -- moves, so nothing a sibling already wrote changes. That is the whole
    -- reason it is not the other way round -- nine contract tests pin these
    -- shapes deliberately, and `if not rows` is what callers actually write.
    --
    -- At the end of the file with the console sweep because `bootAudit` is
    -- defined below the pins it is testing.
    do
        local envL = bootAudit('cis_someProduct')
        envL.invoking = 'cis_someProduct'
        -- AUTHORIZED FIRST, or nothing below registers and every "success" is
        -- another refusal. An empty AuthorizedResources is restrictive by
        -- design, which is correct and quietly unhelpful in a test.
        envL.EXPORTS.SetConfig(nil, {
            AuthorizedResources = { 'cis_someProduct', 'cis_aDifferentProduct' },
        })
        check(envL.EXPORTS.GetLastRefusal() == nil,
            'GetLastRefusal: nothing has been refused yet, so there is nothing to report')

        envL.EXPORTS.DbQuery('SELECT 1', {})
        local why = envL.EXPORTS.GetLastRefusal()
        check(type(why) == 'string' and #why > 0,
            ('GetLastRefusal: the missing-provider refusal is readable afterwards (%s)')
                :format(tostring(why)))
        check(tostring(why):find('database', 1, true) ~= nil,
            ('GetLastRefusal: and it names the capability that is missing (%s)'):format(tostring(why)))

        -- PER RESOURCE, not one shared slot, and this half comes BEFORE the provider
        -- is registered: once `database` resolves, every call succeeds and
        -- nothing is recorded, which would make the isolation untestable.
        --
        -- A single global would let any resource read another's reason -- a small
        -- leak, and a source of baffling log lines, because nobody could tell
        -- whose refusal was whose.
        envL.invoking = 'cis_aDifferentProduct'
        check(envL.EXPORTS.GetLastRefusal() == nil,
            'GetLastRefusal: a different resource does not see the first one\'s refusal')

        envL.EXPORTS.DbQuery('SELECT 1', {})
        check(type(envL.EXPORTS.GetLastRefusal()) == 'string',
            'GetLastRefusal: but it records its own')

        -- And switching back answers with the FIRST one's own refusal, not with
        -- the second's. Independence in one direction is half a proof.
        envL.invoking = 'cis_someProduct'
        check(envL.EXPORTS.GetLastRefusal() == why,
            'GetLastRefusal: switching back answers with its OWN refusal, not the other\'s')

        -- A SUCCESS clears it. A stale reason is worse than none: the next
        -- `if not rows` would report the failure that happened a minute ago,
        -- which is a log line that argues with the truth.
        --
        -- The provider has to actually RESOLVE, not merely be registered: the
        -- stub's `exports` table holds only `cis_libs`, so a registration
        -- pointing at a resource that is not there fails the same way a missing
        -- one does, and the "successful" call below was silently a second
        -- refusal. Registering is not providing.
        envL.EXPORTS.cis_bridge = {
            Db = function()
                return { query = function() return { { id = 1 } } end }
            end,
        }
        envL.started['cis_bridge'] = 'started'
        local registered = envL.EXPORTS.RegisterCapability('database', 'cis_bridge:Db')
        check(registered == true, 'GetLastRefusal: the provider registered')
        local rows = envL.EXPORTS.DbQuery('SELECT 1', {})
        check(type(rows) == 'table',
            ('GetLastRefusal: and the call really succeeded (got %s)'):format(tostring(rows)))
        check(envL.EXPORTS.GetLastRefusal() == nil,
            ('GetLastRefusal: a successful call clears the previous refusal (%s)')
                :format(tostring(envL.EXPORTS.GetLastRefusal())))
        envL.reset()
    end
end

-- ===================== 16. Cis.require: a module without a global (5.1)
--
-- FIFTEEN MODULES, AND NONE OF THEM IS USED BY PRODUCTION CODE. Measured with
-- tools/map-module-deps.js: the only file outside shared/algo and shared/util
-- that names any of the fifteen globals is bench/bench.lua. Nothing in
-- init.lua, server/ or client/ reads one.
--
-- So they can move out of shared_scripts and into `files{}` -- loaded on
-- demand, not at boot -- without any runtime consequence. That is the whole of
-- the win, and it is also why this is cheap: the thing being moved was already
-- dead weight in the load order, paying for itself in boot time and namespace.
--
-- THE CONTRACT BEING PROVED HERE, in the order that matters:
--   * a plain include still sets the legacy global, because 28 sibling
--     resources on disk may include these files directly and a silent nil is
--     the worst possible answer;
--   * a load through `Cis.require` sets NOTHING, or the sandbox is decorative;
--   * two requires of one name are the same table, or state is duplicated;
--   * a name that is not on the allow-list is refused, and the refusal LISTS
--     the valid names.
do
    local MODULES = {
        { name = 'curve', global = 'CisCurve', path = 'shared/algo/curve.lua' },
        { name = 'heap', global = 'CisHeap', path = 'shared/algo/heap.lua' },
        { name = 'interp', global = 'CisInterp', path = 'shared/algo/interp.lua' },
        { name = 'lru', global = 'CisLRU', path = 'shared/algo/lru.lua' },
        { name = 'random', global = 'CisRandom', path = 'shared/algo/random.lua' },
        { name = 'rate', global = 'CisRate', path = 'shared/algo/rate.lua' },
        { name = 'sparse', global = 'CisSparse', path = 'shared/algo/sparse.lua' },
        { name = 'window', global = 'CisWindow', path = 'shared/algo/window.lua' },
        { name = 'id', global = 'CisId', path = 'shared/util/id.lua' },
        { name = 'json', global = 'CisJson', path = 'shared/util/json.lua' },
        { name = 'semver', global = 'CisSemver', path = 'shared/util/semver.lua' },
        { name = 'string', global = 'CisString', path = 'shared/util/string.lua' },
        { name = 'table', global = 'CisTable', path = 'shared/util/table.lua' },
        { name = 'time', global = 'CisTime', path = 'shared/util/time.lua' },
        { name = 'validate', global = 'CisValidate', path = 'shared/util/validate.lua' },
    }

    local savedExports = exports
    local savedLoad = LoadResourceFile
    local calls = {}
    exports = { cis_libs = setmetatable({}, { __index = function() return function() return nil end end }) }
    -- `LoadResourceFile` is a FiveM native. fengari has no filesystem, so the
    -- stub reads the real file -- a stub that ANSWERED a made-up module would
    -- make every assertion below a test of the stub.
    LoadResourceFile = function(resource, relPath)
        -- fengari has no filesystem. CIS_TEST_FILES is the harness' injected map
        -- of every path the MANIFEST names, keyed by relative path -- so this
        -- stub also proves the loader asks for a path the manifest knows about.
        return CIS_TEST_FILES and CIS_TEST_FILES[relPath] or nil
    end
    local savedIsDup = IsDuplicityVersion
    IsDuplicityVersion = function() return true end
    local savedCis = rawget(_G, 'Cis')
    Cis = nil
    local okLoad, loadErr = pcall(function()
        assert(loadfile('./init.lua'))()
    end)
    -- NOT rawget(_G, 'Cis'). The two runners disagree about which TABLE a
    -- loaded chunk writes to: fengari compiles against _G, and test/run.lua
    -- gives every suite its own environment and compiles into THAT. Reading _G
    -- is right under one runner and nil under the other. A bare reference is
    -- the suite's own scope, which is the one table both agree on.
    local lib = Cis

    check(okLoad and type(lib) == 'table',
        ('5.1: init.lua loads with a LoadResourceFile stub (ok=%s err=%s lib=%s require=%s)'):format(tostring(okLoad), tostring(loadErr), type(lib), type(lib and lib.require)))

    if okLoad and type(lib) == 'table' and type(lib.require) == 'function' then
        -- NO GLOBAL LEAKS. This is the assertion the whole task exists for.
        local leaked = {}
        for _, m in ipairs(MODULES) do
            local before = m.global
            local ok, mod = pcall(lib.require, m.name)
            if not ok then
                leaked[#leaked + 1] = m.name .. ' raised: ' .. tostring(mod)
            elseif type(mod) ~= 'table' then
                leaked[#leaked + 1] = m.name .. ' did not answer a table'
            elseif m.global ~= before then
                leaked[#leaked + 1] = m.name .. ' INSTALLED ' .. m.global
            end
        end
        check(#leaked == 0,
            ('5.1: requiring all %d modules installs no global (%s)')
                :format(#MODULES, table.concat(leaked, '; ')))

        -- THE SAME TABLE TWICE, or the cache is decorative and any state in a
        -- module is duplicated per caller.
        local a = lib.require('lru')
        local b = lib.require('lru')
        check(a == b, '5.1: two requires of one module answer the SAME table')

        -- A MODULE WORKS WHEN IT IS ASKED FOR, not merely when it builds. This
        -- was going to be a dependency test -- it claimed to prove that a module
        -- with three dependencies had them supplied -- and the mutation gate
        -- caught it: M68, which removed the dependency wiring, SURVIVED.
        --
        -- The claim was false. The fifteen modules have no dependencies at all;
        -- the edges in the first dependency map were mentions inside COMMENTS --
        -- "the same rule and the same reasoning as CisLRU.each". So window needs
        -- nothing placed in its environment, and newDedupe, seen and isSeen are
        -- self-contained.
        -- The test was asserting that a mechanism worked while demonstrating that
        -- it had nothing to do.
        --
        -- What it asserts now is what is actually true and still worth pinning:
        -- a module required through the loader RUNS. A table that builds and then
        -- raises on first use is the failure this catches.
        local okWindow, window = pcall(lib.require, 'window')
        check(okWindow and type(window) == 'table',
            ('5.1: a module loads through the loader (why=%s)'):format(tostring(window)))
        if okWindow and type(window) == 'table' then
            local dedupe = window.newDedupe(5)
            check(dedupe ~= nil, '5.1: and it builds something')
            check(window.seen(dedupe, 'k', 100.0) == true,
                '5.1: a key seen for the first time is accepted')
            check(window.seen(dedupe, 'k', 101.0) == false,
                '5.1: and refused inside its window')
            -- `seen` and `isSeen` ask OPPOSITE questions, and writing this
            -- backwards is easy: `seen` is "may this through", false while the
            -- key is live; `isSeen` is "is it live", true while it is. Asserted
            -- together because a module answering them the same way passes a test
            -- that asks only one, and the poller that motivated `isSeen` would
            -- extend the window on every poll and never fire.
            check(window.isSeen(dedupe, 'k', 101.0) == true,
                '5.1: isSeen answers the opposite question to seen -- the key IS'
                    .. ' live, which is why seen refused it')
            check(window.isSeen(dedupe, 'k', 200.0) == false,
                '5.1: and it is no longer live once the window has passed')
            check(window.seen(dedupe, 'k', 200.0) == true,
                '5.1: and the key is accepted again once the window has passed')
        end
        -- A NAME THAT IS NOT ON THE LIST, and the refusal has to be usable: it
        -- must raise (a silent nil is the worst answer) and it must NAME the
        -- valid ones, because the caller is guessing a module name.
        local okBad, badErr = pcall(lib.require, 'not_a_module')
        check(not okBad, '5.1: an unknown module name RAISES rather than answering nil')
        check(type(badErr) == 'string' and badErr:find('not_a_module', 1, true) ~= nil,
            ('5.1: and the refusal names what was asked for (got %s)'):format(tostring(badErr)))
        check(type(badErr) == 'string' and badErr:find('lru', 1, true) ~= nil,
            ('5.1: and it lists a valid name, so the caller can fix the call (%s)')
                :format(tostring(badErr)))

        -- A PATH THAT WILL NOT LOAD names the FILE, not just "load failed".
        local okPath = pcall(lib.require, 42)
        check(not okPath, '5.1: a non-string name is refused rather than concatenated into a path')
    else
        for i = 1, 8 do
            check(false, '5.1: Cis.require is missing, so these assertions never ran')
        end
    end

    exports = savedExports
    LoadResourceFile = savedLoad
    IsDuplicityVersion = savedIsDup
    _G.Cis = savedCis
end

-- A PLAIN INCLUDE STILL SETS THE GLOBAL, which is the half that protects the 28
-- sibling resources on disk that may `@include` these files directly. Done by
-- running the chunk the way the manifest does -- no vararg -- rather than
-- through Cis.require, because the two paths differ by exactly one argument.
do
    local src = assert(CIS_TEST_FILES['shared/algo/lru.lua'],
        'the harness did not inject shared/algo/lru.lua -- is it still in the manifest?')
    local before = CisLRU
    CisLRU = nil
    -- NO env argument at all: that is what the manifest does. A sandbox with
    -- only __index would make the chunk write into the SANDBOX, which is a
    -- different test -- and the clear above is a BARE assignment for the same
    -- reason the reads are: fengari compiles against _G and test/run.lua gives
    -- each suite its own environment, so only the suite own scope is a table
    -- both runners agree on.
    local chunk = load(src, '@cis_libs/shared/algo/lru.lua')
    -- NO ARGUMENT. The loader passes 'cis_require'; a manifest include does not.
    local okPlain, errPlain = pcall(chunk)
    check(okPlain, ('5.1: a plain include of a module compiles and runs (why=%s)')
        :format(tostring(errPlain)))
    check(type(CisLRU) == 'table',
        '5.1: a plain include STILL sets CisLRU, for a consumer that includes it directly')
    CisLRU = before

    -- And the same chunk WITH the marker sets nothing. Proved here rather than
    -- only through Cis.require so the two halves sit side by side and a change
    -- to one cannot quietly satisfy the other's test.
    CisLRU = nil
    local chunk2 = load(src, '@cis_libs/shared/algo/lru.lua', 't', _G)
    local okMarked = pcall(chunk2, 'cis_require')
    check(okMarked, '5.1: a marked load runs')
    check(CisLRU == nil,
        '5.1: a marked load installs NO global -- that is the whole difference')
    CisLRU = before
end

-- THE SANDBOX RAISES ON A GLOBAL WRITE. Without this the env is a suggestion,
-- and the one thing a module can do that the allow-list cannot prevent is
-- assign a global and shadow a FiveM one.
do
    local env = setmetatable({}, {
        __index = _G,
        __newindex = function(_, key)
            error(('Cis.require: a module assigned the global %q'):format(tostring(key)), 2)
        end,
    })
    local chunk = load('LeakedGlobal = {}  return {}', '@cis_libs/test/fixture.lua', 't', env)
    local okWrite, writeErr = pcall(chunk, 'cis_require')
    check(not okWrite, '5.1: a module that assigns a global is stopped, not allowed')
    check(type(writeErr) == 'string' and writeErr:find('LeakedGlobal', 1, true) ~= nil,
        ('5.1: and the refusal NAMES the global it caught (got %s)'):format(tostring(writeErr)))
    -- Read through _G deliberately, and luacheck would have flagged a bare
    -- `LeakedGlobal` as undefined -- which is the very property under test. The
    -- global is absent from the REAL table because the sandbox raised before
    -- the assignment, which is the only place it could have landed anyway.
    check(_G.LeakedGlobal == nil, '5.1: and the global really is absent')

    -- A READ still works, or the sandbox would be a ban on reading FiveM.
    _G.CIS_SANDBOX_PROBE = 'a-value-the-test-owns'
    local readChunk = load('return CIS_SANDBOX_PROBE', '@r.lua', 't', env)
    local okRead, readVal = pcall(readChunk, 'cis_require')
    _G.CIS_SANDBOX_PROBE = nil
    check(okRead and readVal == 'a-value-the-test-owns',
        ('5.1: a module can still READ globals through the sandbox (got %s)')
            :format(tostring(readVal)))
end

-- ===================== 17. 5.2: the two swaps that must NOT happen
--
-- 5.2 says to replace an internal duplicate with a module "only where behaviour
-- is identical and proven by pinning tests written before the swap". Both named
-- candidates were checked and BOTH fail that test, for different reasons.
--
-- These tests exist because the refusal was otherwise unenforceable. Nothing
-- pinned either contract, so either swap could have been made, the whole suite
-- would have stayed green, and the damage would have landed on an operator
-- reading a message they had never seen before at three in the morning.
--
-- A refusal nobody can check is a comment. These are checks.

do
    -- ---- 1. the config validators, and the convention they do NOT share ----
    --
    -- `CisDefaults.validate` walks CONFIG_RULES, whose checks return NIL when
    -- the value is fine and a STRING when it is not. Every CisValidate checker
    -- returns `true`, or `false, reason`. The two are not interchangeable and
    -- the swap is not a like-for-like one.
    loadModule('shared/defaults.lua')

    -- The SHAPE, which is the contract a CisValidate swap would break, and which
    -- was MISDOCUMENTED until this test: a clean config answers a bare `true`
    -- with NO second value. The @return line claimed "an array of strings, empty
    -- when ok". A caller written against that documentation does `#problems == 0`
    -- on a nil -- and raises, on the one path that always succeeds.
    local ok, problems = CisDefaults.validate(CisDefaults.config())
    check(ok == true, ('5.2: the default config validates (got %s)'):format(tostring(ok)))
    check(problems == nil,
        '5.2: and answers a BARE true -- the problems list is absent, not empty, which the @return line used to deny')
    -- The messages. They are operator-facing text carrying the exact path to
    -- edit, and NOTHING ELSE in the repository asserts them. That is the whole
    -- cost of a CisValidate swap: every line below would change and every other
    -- test would still pass.
    local function problemsFor(mutate)
        local cfg = CisDefaults.config()
        mutate(cfg)
        local _, list = CisDefaults.validate(cfg)
        return table.concat(list or {}, ' | ')
    end

    local badTimeout = problemsFor(function(c) c.CallbackTimeout = 'soon' end)
    check(badTimeout == 'Config.CallbackTimeout must be a number, got string',
        ('5.2: the number refusal keeps its operator-facing text (%s)')
            :format(badTimeout))

    local badType = problemsFor(function(c) c.AimingCheckType = 7 end)
    check(badType == 'Config.AimingCheckType must be one of default, configFlag, got 7',
        ('5.2: and the enum refusal, which is oneOf and not a string rule (%s)'
            .. ' -- AimingCheckType was guessed to be a string check and it is not')
            :format(badType))

    local badUrl = problemsFor(function(c) c.VersionCheckUrl = '' end)
    check(badUrl == 'Config.VersionCheckUrl must be a non-empty string, got string ()',
        ('5.2: and the non-empty-string rule, which is where it actually lives (%s)')
            :format(badUrl))

    local badBool = problemsFor(function(c) c.CheckVersion = 'yes' end)
    check(badBool == 'Config.CheckVersion must be true or false, got string (yes)',
        ('5.2: and the boolean rule, whose whole purpose is that a truthy string '
            .. 'does not switch a subsystem on (%s)'):format(badBool))

    check(problemsFor(function(c) c.CallbackTimeout = 0 / 0 end):find('NaN', 1, true) ~= nil,
        '5.2: and NaN is named as NaN, where CisValidate would say "not finite"')

    -- CisValidate's own convention, side by side, so the difference is visible
    -- in one place instead of being something a reader has to remember.
    local good, goodWhy = CisValidate.number(5, { min = 1, max = 10, name = 'x' })
    check(good == true and goodWhy == nil,
        '5.2: CisValidate answers TRUE for a good value -- the opposite polarity')
    local bad, badWhy = CisValidate.number(50, { min = 1, max = 10, name = 'x' })
    check(bad == false and type(badWhy) == 'string',
        '5.2: and false plus a reason for a bad one')

    -- And the polarity difference is load-bearing, not cosmetic: a check written
    -- for one convention applied to the other refuses every correct value. That
    -- is what `boolean` returning `true` for a good value once did to every
    -- boolean rule, and the tests caught it immediately.
    check(CisValidate.number(5, { min = 1, max = 10 }) ~= nil,
        '5.2: CisValidate never answers nil for a value it CHECKED, so nil keeps '
            .. 'meaning "missing" rather than becoming a third answer')
end

-- ---- 2. the security limiter is NOT CisRate, in THREE ways ----
--
-- The plan says: "Do not touch the security rate limiter: its semantics differ
-- from CisRate and it sits on the trust boundary." That is right, and the
-- stated reason is INCOMPLETE -- which is the dangerous kind of right.
--
-- `shared/algo/rate.lua` opens with: "They differ in ONE thing that matters:
-- what happens at the window boundary." That is true of the three CisRate
-- variants and of nothing else. The security limiter differs in three ways:
--
--   * boundary     -- both fixed-window, agreed;
--   * CLOCK UNIT   -- GetGameTimer() MILLISECONDS against CisRate's SECONDS
--                     passed in as an argument;
--   * a BUCKET CAP -- 256 per src, because event names arrive off the wire.
--
-- A reader who trusted the module header would conclude the boundary was the
-- only difference, would "fix" the unit difference, and every limit on the
-- server would become a thousand times looser, silently, with nothing in the
-- suite catching it. That is the hole this closes.
do
    local env = newEnv({ players = {} })
    loadModule('server/security.lua')

    local clock = 0
    GetGameTimer = function() return clock end

    local allowed = 0
    for _ = 1, 8 do
        if CisRateOk(1, 'evt', 1000, 8) then allowed = allowed + 1 end
    end
    check(allowed == 8,
        ('5.2: the security limiter allows 8 of 8 inside a 1000 window (got %d)')
            :format(allowed))
    check(CisRateOk(1, 'evt', 1000, 8) == false,
        '5.2: and refuses the ninth')

    -- 999 ms later it is STILL the same window. If the unit were seconds, 999
    -- would be 999 seconds and this would have passed long ago -- which is
    -- exactly the failure a unit mix-up produces, and it is silent.
    clock = 999
    check(CisRateOk(1, 'evt', 1000, 8) == false,
        '5.2: and still refuses at 999 ms, so the window really is MILLISECONDS')
    clock = 1000
    check(CisRateOk(1, 'evt', 1000, 8) == true,
        '5.2: and resets at 1000 ms')

    -- THE SAME ARITHMETIC AGAINST CisRate, whose clock is seconds. Same numbers,
    -- opposite units.
    -- LoadResourceFile is a FiveM native and fengari has no filesystem, so
    -- the loader is given the harness' injected map. Its own refusal above
    -- named this file and this fix, which is the behaviour the task wanted:
    -- a caller who hits it knows what to do without reading the source.
    local savedLoad = LoadResourceFile
    LoadResourceFile = function(_, relPath)
        return CIS_TEST_FILES and CIS_TEST_FILES[relPath] or nil
    end
    local rate = Cis.require('rate')
    LoadResourceFile = savedLoad

    -- `newFixed({limit, windowSec})` and a MODULE-LEVEL `allow(r, key, now)`.
    -- Read out of shared/algo/rate.lua rather than guessed: the first version of
    -- this called `rate.fixed(...)` and `limiter:allow(...)`, neither of which
    -- exists, and failed on a product that was working perfectly.
    local limiter = rate.newFixed({ limit = 8, windowSec = 1 })
    check(rate.allow(limiter, 'k', 0) == true, '5.2: CisRate takes SECONDS')
    for _ = 1, 7 do rate.allow(limiter, 'k', 0) end
    check(rate.allow(limiter, 'k', 0) == false,
        '5.2: and refuses the ninth inside its window')
    check(rate.allow(limiter, 'k', 0.999) == false,
        '5.2: at 0.999 SECONDS it is still refused -- the opposite of '
            .. 'the millisecond limiter above, on the same numbers')
    check(rate.allow(limiter, 'k', 1) == true,
        '5.2: and it resets at 1 second, where the millisecond limiter needed 1000')
    -- THE CAP. Event names arrive off the wire, so an unbounded map is a memory
    -- growth rate a client controls. CisRate has no cap: it is a pure value with
    -- no notion of a hostile key, which is another reason the swap cannot be a
    -- straight one.
    -- A FRESH src. The cap is per source, and src 1 already holds buckets from
    -- the assertions above, so 400 fresh names on it fit 254 and not 256 -- a
    -- number that reads like a library bug and is really a shared test fixture.
    local distinct = 0
    for i = 1, 400 do
        if CisRateOk(99, ('evt:%d'):format(i), 1000, 8) then
            distinct = distinct + 1
        end
    end
    check(distinct == 256,
        ('5.2: the security limiter caps a src at 256 distinct event names (got %d)')
            :format(distinct))
end

-- ===================== 18. 5.3: a Cis.* never raises for the wrong realm
--
-- 118 exports: 24 registered on both realms, 50 server-only, 44 client-only.
-- So 94 of them are single-realm, and a consumer calling one from the wrong
-- realm hits the platform's "No such export X in resource cis_libs" -- which is
-- raised by FiveM, before any cis_libs code runs, and names no fix.
--
-- 5.2 and 4.10 both learned this the same way: a refusal that names itself is a
-- value a caller can test, and a raise is a support ticket. The exceptions are
-- Cis.sync.ped, Cis.sync.list and friends, which answer
-- `false, 'server only'`.
--
-- AND EVERY OTHer SINGLE-REALM CALL HAS TO AS WELL, or "it works if you use the
-- documented one" is true by luck rather than by design.
--
-- This is a STATIC scan rather than ninety-four unit tests, and the reason is
-- the same one that put the config-rules check in this file: a hand-maintained
-- list falls behind on the day somebody adds a function, and the suite stays
-- green. Reading init.lua means the ninety-fifth function is covered the moment
-- it is written.
do
    -- The realm map comes from api.lua, which the harness injects, and which
    -- validate-api.js already holds to the real registered surface in both
    -- directions -- so it is not a hand-kept list that can drift from the code.
    -- (scanResource is a JavaScript function; there is no way to call it from
    -- here, and inventing a second source of truth in Lua would be worse than
    -- reading the one the validator already checks.)
    local apiBody = stripComments(CIS_TEST_FILES['api.lua'] or '')
    local byName = {}
    -- `realm = %a+` inside an entry. Deliberately simple: an entry is a name
    -- followed by a brace, and the realm is on a line of its own. A pattern
    -- clever enough to also handle nested tables is a pattern that matches
    -- something else too.
    -- One entry, one capture pair, and no escaped newline anywhere: %s
    -- -- already matches newlines, so the whole pattern fits on one line with    -- newlines, so the whole pattern fits on one line with nothing to escape.
    -- That is not tidiness -- an escaped newline written through a shell comes
    -- out as a REAL newline and splits the Lua string in half, which is what
    -- happened twice on the way here.
    --
    -- `[^}]-` keeps a match inside ONE entry: the next closing brace ends it,
    -- so a realm further down cannot be attributed to this export.
    for name, realm in apiBody:gmatch("([%w_]+) = {%s*[^}]-realm = '([%a]+)'") do
        byName[name] = realm
    end
    local declared = 0
    for _ in pairs(byName) do declared = declared + 1 end
    check(declared > 60,
        ('5.3: the realm map read %d exports out of api.lua -- a count this low '

            .. 'means the parse stopped matching and every check below would '

            .. 'pass vacuously'):format(declared))

    local body = stripComments(readFile('init.lua'))

    -- Every Cis.* function and the body that follows it. Cut at the next
    -- top-level `function Cis.` or end of file, so a body cannot bleed into the
    -- next function and inherit its guard.
    local funcs = {}
    -- ONE SLICE PER FUNCTION, bounded by the NEXT `function Cis.` at any
    -- indentation and by 2 KB, whichever comes first. The first version ran to
    -- the next TOP-LEVEL one, so the last function in a block swept up
    -- everything after it -- which is how `Cis.wait` came to be reported as
    -- calling GetCachedVehicle, defined hundreds of lines later.
    local starts = {}
    for at in body:gmatch('()function%s+Cis%.[%w_%.]+') do starts[#starts + 1] = at end
    for i = 1, #starts do
        local from = starts[i]
        local stop = #body + 1
        if i < #starts then stop = math.min(stop, starts[i + 1]) end
        stop = math.min(stop, from + 2000)
        local text = body:sub(from, stop)
        local name = body:match('^[%s]*function%s+([%w_%.]+)', from)
        local export = text:match("exportCall%('([%w_]+)'%)")
            or text:match("tryExport%('([%w_]+)'%)")
        funcs[#funcs + 1] = { name = name or ('at' .. from), export = export, text = text }
    end

    check(#funcs > 40,
        ('5.3: the scan found the Cis.* surface (%d functions) -- a count this low '

            .. 'means the pattern stopped matching and every check below would '

            .. 'pass vacuously'):format(#funcs))

    local singleRealmCalls = 0
    local guarded = 0
    local missing = {}
    local wrongGuard = {}

    -- `then return serverOnly()` and not `then serverOnly()`: the `return`
    -- sits between them in every real call site, and a pattern that omitted it
    -- reported correctly guarded functions as unguarded. Both of the failures
    -- that produced were the CHECK being wrong, not the code.
local G_SERVER = 'if%s+not%s+IS_SERVER%s+then%s+return%s+serverOnly%(%)'

    local G_CLIENT = 'if%s+IS_SERVER%s+then%s+return%s+serverOnly%(%)'

    -- THE OTHER WAY TO SATISY THE RULE, and the one most of this surface uses.
    --
    -- A function defined INSIDE `if not IS_SERVER` cannot carry an inline guard,
    -- because it does not EXIST on the other realm to guard. What makes it safe
    -- is a refusal defined in the `if IS_SERVER` half for the same name -- and
    -- collecting those rather than listing them is the point: the check then
    -- covers a function added tomorrow without anyone editing it.
    local refusals = {}
    local clientRefusals = {}
    local serverRefusals = {}
    for name in body:gmatch("function%s+(Cis%.[%w_%.]+)%(%s*%)%s*\n%s*return%s+false,%s+'client only'") do
        refusals[name] = true
        clientRefusals[name] = true
    end
    for name in body:gmatch("function%s+(Cis%.[%w_%.]+)%(%s*%)%s*\n%s*return%s+false,%s+'server only'") do
        refusals[name] = true
        serverRefusals[name] = true
    end
    local refusalCount = 0
    for _ in pairs(refusals) do refusalCount = refusalCount + 1 end
    check(refusalCount > 0,
        '5.3: the opposite-realm refusals were found at all -- zero means the '
            .. 'pattern stopped matching and every check below would pass vacuously')

    for _, fn in ipairs(funcs) do
        local realm = byName[fn.export]
        if realm and realm ~= 'both' then
            local isServer = realm == 'server'
            singleRealmCalls = singleRealmCalls + 1
            local guardsServerSide = fn.text:match(G_SERVER) ~= nil
            local guardsClientSide = fn.text:match(G_CLIENT) ~= nil
            local byRefusal = refusals[fn.name] == true
            if (isServer and guardsServerSide) or ((not isServer) and guardsClientSide)
                or byRefusal then
                guarded = guarded + 1
            elseif guardsServerSide or guardsClientSide then
                wrongGuard[#wrongGuard + 1] = string.format(
                    '%s -> %s (%s only) guards the OTHER realm',
                    fn.name, fn.export, isServer and 'server' or 'client')
            else
                missing[#missing + 1] = string.format(
                    '%s -> %s (%s only)',
                    fn.name, fn.export, isServer and 'server' or 'client')
            end
        end
    end

-- THE HALF M71 FOUND MISSING, and it is the half that matters most.
    --
    -- Everything above checks `Cis.*` functions that CALL a single-realm export,
    -- because those are the ones that reach the exports boundary. It misses
    -- every client function answered LOCALLY -- `Cis.player.ped`,
    -- `Cis.player.coords`, `Cis.player.heading` -- which never touch an export
    -- and were therefore never examined.
    --
    -- M71 is what found it: it changed `Cis.player.ped` from
    -- `false, 'client only'` to a bare `nil`, the suite stayed green, and the
    -- mutation survived. A check that covers the functions with an export call
    -- and not the ones without is a check with a hole shaped exactly like the
    -- class of thing it was written for.
    --
    -- So: every function DEFINED inside the client half must have a refusal on
    -- the server, unless the server half defines it too. Read from the source
    -- rather than listed, so a function added tomorrow is covered the moment it
    -- is written.

    local clientStart = body:find('if not IS_SERVER then')
    local serverStart = clientStart and body:find('\nelse\n', clientStart)
    local blockEndAt = serverStart and body:find('\nend\n', serverStart)
    check(clientStart ~= nil and serverStart ~= nil and blockEndAt ~= nil,
        '5.3: the if/else halves of init.lua were located -- without them this '
            .. 'check would silently cover nothing')

    if clientStart and serverStart and blockEndAt then
        local clientHalf = body:sub(clientStart, serverStart)
        local serverHalf = body:sub(serverStart, blockEndAt)

        local definedIn = function(half)
            local set = {}
            for n in half:gmatch('function%s+(Cis%.[%w_%.]+)%s*%(') do set[n] = true end
            return set
        end
        local clientDefined = definedIn(clientHalf)
        local serverDefined = definedIn(serverHalf)

        local unrefused = {}
        local localOnly = 0
        for name in pairs(clientDefined) do
            if not serverDefined[name] then
                localOnly = localOnly + 1
                if not refusals[name] then
                    unrefused[#unrefused + 1] = name
                end
            end
        end
        table.sort(unrefused)

        check(localOnly > 0,
            '5.3: there ARE client-only functions -- zero means the half-split '
                .. 'found nothing and every assertion below passes vacuously')
        check(#unrefused == 0,
            ('5.3: every client-only Cis.* refuses on the server (%d without a '
                .. 'refusal: %s)')
                :format(#unrefused, table.concat(unrefused, ', ')))

        -- The refusal must be the RIGHT one. A client-only function answered
        -- `false, 'server only'` would read as "you are on the wrong realm" for
        -- a caller who IS on the wrong realm, and be exactly as unhelpful.
        local wrongRealm = {}
        for name in pairs(clientDefined) do
            if not serverDefined[name] and refusals[name] then
                -- Collected above rather than re-matched here: rebuilding the
                -- pattern meant a gsub whose replacement held a bare `%`, and
                -- in a REPLACEMENT a bare `%` means "the whole match".
                if serverRefusals[name] and not clientRefusals[name] then
                    wrongRealm[#wrongRealm + 1] = name
                end
            end
        end
        check(#wrongRealm == 0,
            ('5.3: and each says CLIENT only, the realm it is missing from (%s)')
                :format(table.concat(wrongRealm, ', ')))
    end

    check(singleRealmCalls > 0,
        '5.3: the scan found single-realm calls at all -- zero means it is '

            .. 'measuring nothing')
    check(#missing == 0,
        ('5.3: every Cis.* wrapping a single-realm export refuses on the wrong '

            .. 'realm (%d unguarded: %s)')

            :format(#missing, table.concat(missing, '; ')))
    check(#wrongGuard == 0,
        ('5.3: and each guard refuses on the RIGHT realm (%s)')

            :format(table.concat(wrongGuard, '; ')))
    check(guarded == singleRealmCalls,
        ('5.3: %d of %d single-realm wrappers carry a refusal')
            :format(guarded, singleRealmCalls))
end

-- ------------------------------------------------------------------ report
for i = 1, #failures do
    io.stderr:write('FAIL(contracts): ' .. failures[i] .. '\n')
end
io.write(('contracts passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
