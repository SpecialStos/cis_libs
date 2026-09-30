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
--   3. Cis.db.transaction on a non-oxmysql driver still returns
--      `false, 'transactions require oxmysql'` byte for byte, and now also
--      says why on the console.
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
-- assertions -- this library must not call ox_target, must not name cis_doors
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
    function CreateThread(fn)
        fn()
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
    function GetPlayerName() return 'TestPlayer' end
    function DropPlayer() end
    function AddEventHandler() end
    function RegisterNetEvent() end
    function RegisterCommand() end
    function GetResourceMetadata(_, field) return field == 'version' and '1.0.0' or '' end
    function PerformHttpRequest(url, cb)
        env.http[#env.http + 1] = url
        if cb then
            cb(200, '1.0.0\n')
        end
    end
    function LoadResourceFile(_, path) return env.marker end
    function SaveResourceFile(_, path, body)
        env.marker = body
        return true
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
    Citizen = {
        Await = function(p)
            if not p.done then
                error('promise was awaited before it settled; the stub is synchronous')
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
    check(#env.http == 0, 'default install fires no outbound request')

    -- Opted in: the endpoint comes from config, and it is the config's URL.
    env.http = {}
    Config.CheckVersion = true
    loadModule('server/version.lua')
    check(#env.http == 1, ('opt-in fires exactly one request (got %d)'):format(#env.http))
    check(env.http[1] == Config.VersionCheckUrl,
        'the request goes to Config.VersionCheckUrl, not to a hardcoded host')

    -- Opted in with no endpoint configured: warn, do not guess a host.
    env.http = {}
    Config.VersionCheckUrl = nil
    loadModule('server/version.lua')
    check(#env.http == 0, 'a missing VersionCheckUrl produces no request')

    -- The resource-level helper is untouched by any of the above.
    local crc = env.EXPORTS.CheckResourceVersion
    check(type(crc) == 'function', 'CheckResourceVersion is still exported')
    local before = #env.http
    check(crc(nil, 'https://x.invalid', '1.0.0') == nil,
        'CheckResourceVersion ignores a non-string resource name')
    check(#env.http == before, 'a rejected CheckResourceVersion call sends nothing')
    env.http = {}
    crc('someResource', 'https://x.invalid/v.txt', '1.0.0')
    check(#env.http == 1, 'CheckResourceVersion still performs its request')

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
    check(env.marker ~= nil, 'new install: a marker is written so the decision is stable')
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

    -- Legacy install, signal 1: a written config already exists.
    env = securityScenario({ authorized = {}, marker = '{"restricted":true}' })
    check(env.EXPORTS.InvokingAllowed() == true,
        'legacy install (written config present) keeps the permissive path')
    check(mentions(env, 'PERMISSIVE'), 'legacy install: the console says it is permissive')
    check(not mentions(env, 'REFUSED'), 'legacy install: no refusal is announced')
    CisInvokingAllowed = nil
    env.reset()

    -- Legacy install, signal 2: a storing product is installed and it already
    -- holds rows. Before the split this was a SELECT against cis_doors; the
    -- product now answers the same question about its own store.
    env = securityScenario({
        authorized = {},
        persisted = true,
        hasRows = true,
    })
    check(env.EXPORTS.InvokingAllowed() == true,
        'legacy install (store already populated) keeps the permissive path')
    check(mentions(env, 'PERMISSIVE'), 'legacy install: the console says it is permissive')
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

    -- Unclassifiable: a product that persists is installed but never answered.
    -- Today this install is permissive, and it must stay that way -- refusing on
    -- a server we could not read would be the worse failure.
    env = securityScenario({ authorized = {}, persisted = true })
    check(env.EXPORTS.InvokingAllowed() == true,
        'an install that cannot be classified stays permissive')
    check(mentions(env, 'not classified'),
        'an unclassified install says so instead of refusing silently')
    CisInvokingAllowed = nil
    env.reset()

    -- A populated list behaves exactly as it always has, on any install.
    env = securityScenario({ authorized = { 'cis_storeRobberies' }, marker = '{"restricted":true}' })
    env.invoking = 'cis_storeRobberies'
    check(env.EXPORTS.InvokingAllowed() == true, 'a listed resource is allowed')
    env.invoking = 'cis_someOther'
    check(env.EXPORTS.InvokingAllowed() == false, 'an unlisted resource is refused')
    check(not mentions(env, 'REFUSED'),
        'a populated list emits no empty-list warning')
    CisInvokingAllowed = nil
    env.reset()

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
        if env.lines[i]:find('no provider for', 1, true) then
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

    -- KNOWN DEFECT, pinned rather than fixed. The freeze forbids a behaviour
    -- change, and this is one: on the client, Cis.framework.notify(message,
    -- kind) sends `kind` where the message belongs. init.lua's two client
    -- branches disagree -- the one-argument form sends the first argument, the
    -- two-argument form sends the second -- and the client Notify export takes
    -- (message, kind). Correcting it is a MAJOR change, so the current
    -- behaviour is pinned here and called out in COMPATIBILITY.md section 8.
    -- If this assertion ever flips, that is the fix landing on purpose.
    calls = {}
    Cis.framework.notify('hi')
    check(f(calls[1], 2) == 'hi', 'client notify: a one-argument call sends the message')
    calls = {}
    Cis.framework.notify('hi', 'error')
    check(f(calls[1], 2) == 'error',
        'client notify: DEFECT PINNED -- the kind is sent in the message slot')
    check(f(calls[1], 3) == nil,
        'client notify: DEFECT PINNED -- the kind slot arrives empty')

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
    routesTo(function() Cis.callback.call('x', nil) end, 'CallCallback', 'callback.call')
    routesTo(function() Cis.callback.callClient(1, 'x', nil) end, 'CallCallbackClient', 'callback.callClient')
    routesTo(function() Cis.callback.awaitClient(1, 'x') end, 'AwaitCallbackClient', 'callback.awaitClient')
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
    routesTo(function() Cis.callback.call('x', nil) end, 'CallCallback', 'callback.call (client)')

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

-- ========================================= 5. this library owns no table
-- THE INVARIANT THE WHOLE PLATFORM IS BUILT ON.
--
-- "cis_libs must own zero tables. A server owner deletes libraries when they
-- are unhappy; they cannot delete their player records. That property is what
-- makes trying CIsoko safe, and safe trial is the single biggest driver of
-- adoption."
--
-- A property this load-bearing cannot be left to a review comment. It is
-- asserted here against every Lua file the manifest actually loads, so the
-- first person who adds a CREATE TABLE to a convenience helper breaks the
-- suite rather than the promise.
do
    local manifest = readFile('fxmanifest.lua')
    local violations = {}
    for line in manifest:gmatch("'([%w_/%.]+%.lua)'") do
        local body = readCode(line)
        -- CREATE TABLE, in any case, in any driver dialect.
        if body:find('CREATE%s+TABLE', 1, true) == nil
            and body:find('create%s+table', 1, true) == nil
            and body:find('createTable', 1, true) == nil
        then
            -- fine
        else
            violations[#violations + 1] = line .. ' (CREATE TABLE)'
        end
        -- A write to a table, whether or not it is one we own. A library that
        -- INSERTs somewhere is a library that owns a table, whatever it calls
        -- the table.
        if body:find('INSERT%s+INTO', 1, true) then
            violations[#violations + 1] = line .. ' (INSERT INTO)'
        end
    end
    check(#violations == 0,
        'no file in cis_libs creates or writes a table: ' .. table.concat(violations, ', '))

    -- And the flip side, which is what actually makes the above hold: the
    -- library has no driver to write with. A stray `exports.oxmysql:` in a
    -- helper is the same promise broken by a different route.
    local thirdParty = {}
    for _, needle in ipairs({
        'exports.oxmysql', "exports['oxmysql']", 'exports.mysql', "exports['mysql-async']",
        'exports.ghmattimysql', 'exports.mongodb',
        'exports.ox_target', "exports['qb-target']",
        'exports.ox_inventory', "exports['qb-inventory']", "exports['qs-inventory']",
        "exports['codem-inventory']",
        'exports[\'es_extended\']', "exports['qb-core']", 'exports.qbx_core', 'exports.qb_core',
    }) do
        for line in manifest:gmatch("'([%w_/%.]+%.lua)'") do
            if readCode(line):find(needle, 1, true) then
                thirdParty[#thirdParty + 1] = ('%s -> %s'):format(line, needle)
            end
        end
    end
    check(#thirdParty == 0,
        'no file in cis_libs calls a third-party resource: ' .. table.concat(thirdParty, ', '))
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

    -- A configured list is a definite answer; it must settle the posture.
    -- Located with PLAIN search rather than a Lua pattern: a non-greedy
    -- pattern stops at the first `end`, which here is the `for` loop's, and
    -- the assertion silently inspects the wrong slice. That failure mode is
    -- the reason this test exists in the first place.
    local from = secSource:find('local list = configuredList', 1, true)
    local to = from and secSource:find('\n        return', from, true)
    local branch = (from and to) and secSource:sub(from, to) or nil
    check(branch ~= nil, 'the configured-list branch is locatable in security.lua')
    check(branch and branch:find("posture = 'configured'", 1, true) ~= nil,
        'a configured allow-list marks the posture decided, so no legacy query runs')

    -- And the deferred probe must ask a product, not a table.
    local pFrom = secSource:find('if posture == nil then', 1, true)
    local pTo = pFrom and secSource:find('\nend', pFrom, true)
    local probe = (pFrom and pTo) and secSource:sub(pFrom, pTo) or nil
    check(probe ~= nil, 'security.lua has a deferred posture resolution')
    check(probe and probe:find('persistConfigured', 1, true) ~= nil,
        'the deferred probe is gated on a storing product being installed')
    check(probe and probe:find('dataProbe', 1, true) ~= nil,
        'the deferred probe waits for a product that can answer the question')

    -- The regression itself: this library must not name a table it does not own.
    -- A grep-level assertion, because the failure it guards is a string that
    -- belongs in a product and a reviewer would reasonably not question here.
    check(secSource:find('cis_doors', 1, true) == nil,
        'security.lua no longer names cis_doors, a table this library does not own')
end

-- ------------------------------------------------------------------ report
for i = 1, #failures do
    io.stderr:write('FAIL(contracts): ' .. failures[i] .. '\n')
end
io.write(('contracts passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
