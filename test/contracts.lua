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
do
    local env = newEnv()
    loadModule('configs/master_config.lua')

    check(Config.CheckVersion == false,
        ('Config.CheckVersion defaults off (got %s)'):format(tostring(Config.CheckVersion)))
    check(type(Config.VersionCheckUrl) == 'string' and Config.VersionCheckUrl ~= '',
        'Config.VersionCheckUrl is a non-empty string')
    check(not Config.VersionCheckUrl:find('specialstos', 1, true),
        'Config.VersionCheckUrl names no personal GitHub Pages host')
    check(Config.VersionCheckUrl:find('cisoko', 1, true) ~= nil,
        'Config.VersionCheckUrl is a CIsoko-controlled endpoint')

    -- The literal the old default was built from must not survive anywhere.
    for _, rel in ipairs({ 'configs/master_config.lua', 'server/version.lua' }) do
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
local function securityScenario(opts)
    local env = newEnv(opts)
    loadModule('configs/master_config.lua')
    -- Use the shipped default unless the scenario overrides it, so the tests
    -- exercise the value a real install would have.
    if not opts.persist then
        Config.Doorlock.Persist = false
    else
        Config.Doorlock.Persist = true
    end
    loadModule('configs/security_config.lua')
    if opts.authorized then
        Security.AuthorizedResources = opts.authorized
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

    -- Legacy install, signal 2: cis_doors has persisted rows.
    env = securityScenario({
        authorized = {},
        persist = true,
        started = { oxmysql = 'started' },
        dbRows = { { id = 'bank_door' } },
    })
    check(env.EXPORTS.InvokingAllowed() == true,
        'legacy install (cis_doors populated) keeps the permissive path')
    check(mentions(env, 'PERMISSIVE'), 'legacy install: the console says it is permissive')
    CisInvokingAllowed = nil
    env.reset()

    -- New install that enabled persistence: the table exists but is empty.
    env = securityScenario({
        authorized = {},
        persist = true,
        started = { oxmysql = 'started' },
        dbRows = {},
        invoking = 'cis_someProduct',
    })
    check(env.EXPORTS.InvokingAllowed() == false,
        'new install with an empty cis_doors is restrictive')
    check(mentions(env, 'REFUSED'), 'new install with persistence: the refusal is announced')
    CisInvokingAllowed = nil
    env.reset()

    -- Unclassifiable: persistence is on but the driver never started. Today
    -- this install is permissive, and it must stay that way.
    env = securityScenario({ authorized = {}, persist = true, started = {} })
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

-- ==================================== 3. Cis.db.transaction on a bad driver
do
    local function dbScenario(opts)
        local env = newEnv(opts)
        loadModule('configs/master_config.lua')
        Config.Framework.Database.Type = opts.driver
        loadModule('server/database.lua')
        return env
    end

    local env = dbScenario({ driver = 'mysql-async', started = { ['mysql-async'] = 'started' } })
    check(mentions(env, 'mysql-async'),
        'boot diagnostic names the configured driver')
    check(mentions(env, 'Cis.db.transaction'),
        'boot diagnostic names the API that is unavailable')
    check(mentions(env, 'oxmysql'),
        'boot diagnostic names the driver to switch to')
    check(#env.http == 0, 'the boot diagnostic itself makes no request')

    -- DEFECT 9.2, now FIXED. `exportAwait` calls `method(sql, params, cb)`, but
    -- Database.Transaction takes (queries, cb) -- so the completion callback
    -- arrived in a third parameter the function never read. The await never
    -- settled, spun out the full Database.Timeout, and returned nothing, while
    -- the driver logged a parameter error on every call. `DbTransaction` is
    -- now written out longhand so the callback reaches slot 2.
    --
    -- On a bad driver it must still refuse rather than throw, and it must
    -- refuse PROMPTLY: the whole point of the fix is that a refusal is not
    -- paid for with a 15-second stall.
    local startedAt = env.clock
    local a, b = env.EXPORTS.DbTransaction({ { query = 'SELECT 1' } })
    check(a == false,
        'DbTransaction on a bad driver refuses with false rather than throwing')
    check(type(b) == 'string' and b ~= '',
        'the refusal carries a reason a caller can log: ' .. tostring(b))
    check(env.clock - startedAt < Config.Framework.Database.Timeout,
        'a refused transaction does not cost the full Database.Timeout')
    check(#env.http == 0, 'a refused transaction makes no request')
    check(mentions(env, 'called by'),
        'the refusal names the resource that called it')
    -- One-shot by design, so the naming is checked on a fresh install: a
    -- second call must not re-announce itself.
    env.EXPORTS.DbTransaction({})
    local repeats = 0
    for i = 1, #env.lines do
        if env.lines[i]:find('refused; called by', 1, true) then
            repeats = repeats + 1
        end
    end
    check(repeats == 1, 'the call-time refusal is announced once, not once per call')
    env.reset()

    env = dbScenario({
        driver = 'mysql-async',
        started = { ['mysql-async'] = 'started' },
        invoking = 'cis_phone',
    })
    env.EXPORTS.DbTransaction({})
    check(mentions(env, 'cis_phone'),
        'the refusal names the invoking resource, not cis_libs')
    -- The string a fix must preserve still exists verbatim.
    check(readFile('server/database.lua'):find("'transactions require oxmysql'", 1, true) ~= nil,
        'the refusal string a fix must preserve is unchanged in source')
    env.reset()

    -- oxmysql is the supported driver and must say nothing.
    env = dbScenario({ driver = 'oxmysql', started = { oxmysql = 'started' } })
    check(not mentions(env, 'does not support transactions'),
        'oxmysql raises no transaction diagnostic')
    check(not mentions(env, 'refused; called by'),
        'oxmysql raises no refusal line')
    env.reset()

    -- An unavailable driver is still reported, without inventing a transaction
    -- problem it does not have.
    env = dbScenario({ driver = 'oxmysql', started = {} })
    check(mentions(env, 'Database driver unavailable'),
        'an unavailable driver still reports as before')
    check(not mentions(env, 'does not support transactions'),
        'an unavailable driver raises no transaction diagnostic')
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

-- ============================================= 5. cross-file globals resolve
-- A file-local read from another file is nil at runtime and raises nothing,
-- which is the same failure shape as the self trap: silent, total, and
-- invisible in the documentation.
--
-- `Database` was `local` in server/database.lua while server/initialize.lua
-- read a global of that name to report `databaseReady`. The field was therefore
-- permanently false on every server, including ones whose driver had started
-- cleanly. This pins the declaration so it cannot quietly go back.
do
    local dbSource = readFile('server/database.lua')
    local initSource = readFile('server/initialize.lua')

    check(initSource:find('Database%s*and%s*Database%.ready') ~= nil,
        'initialize.lua reads Database.ready to build the config summary')
    check(dbSource:find('local%s+Database%s*=%s*{') == nil,
        'Database is NOT a file local -- another realm would read nil')
    check(dbSource:find('\nDatabase%s*=%s*{') ~= nil,
        'server/database.lua declares Database as a global')
    check(dbSource:find('Database%.ready%s*=%s*Database%.driver%s*~=%s*nil') ~= nil,
        'Database.ready is derived from the selected driver, not left constant')
end

-- ============================================ 6. the doorlock probe stays quiet
-- `cis_doors` is created ONLY when Config.Doorlock.Persist is on. The
-- legacy-detection probe used to query it unconditionally whenever the posture
-- was still undecided -- including on every server that HAD an allow-list
-- configured, because that branch returned without marking the posture decided.
-- So a default install printed a database error naming a table that was never
-- meant to exist, on every boot, for a condition the operator could not act on.
do
    local secSource = readFile('server/security.lua')

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

    -- And the deferred probe must not ask about a table that may not exist.
    local pFrom = secSource:find('if posture == nil then', 1, true)
    local pTo = pFrom and secSource:find('\nend', pFrom, true)
    local probe = (pFrom and pTo) and secSource:sub(pFrom, pTo) or nil
    check(probe ~= nil, 'security.lua has a deferred posture resolution')
    check(probe and probe:find('persistConfigured', 1, true) ~= nil,
        'the deferred probe is gated on persistence being configured')
end

-- ------------------------------------------------------------------ report
for i = 1, #failures do
    io.stderr:write('FAIL(contracts): ' .. failures[i] .. '\n')
end
io.write(('contracts passed=%d failed=%d\n'):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
