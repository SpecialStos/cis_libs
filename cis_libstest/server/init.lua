-- Server entry point. Runs the server suite, asks clients to run theirs,
-- aggregates both, and writes a single JSON report into the resource folder.

local reports = CisTestReport.new()
local clientSubmissions = {}
local pendingClientIds = {}
local pendingCount = 0
local running = false
local collected = true
-- Forward-declared: the submit handler below is registered before collect is
-- defined, so without this it resolves to a nil global at call time.
local collect

-- Records what arrives from the client-side relay. This is the only way a
-- consumer resource can observe a zone or proximity callback, because a
-- function cannot cross the exports boundary -- an event name can.
local relay = {}

local function record(kind)
    return function(zoneName, a, b, c)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        relay[#relay + 1] = {
            kind = kind,
            zone = zoneName,
            a = a, b = b, c = c,
            player = src,
            at = os.time(),
        }
        if #relay > 200 then
            table.remove(relay, 1)
        end
    end
end

for _, kind in ipairs({ 'zoneEnter', 'zoneExit', 'zoneInside', 'nearEnter', 'nearExit' }) do
    RegisterNetEvent('cis_libstest:' .. kind, record(kind))
end

-- `src` is the first argument cis_libs passes to any handler. Echoing it back
-- lets a client prove the source survived a real net event, which a
-- resource-local TriggerEvent cannot (it sets no source at all).
exports('cis_test:getRelay', function(sinceKind)
    local out = {}
    for i = 1, #relay do
        if not sinceKind or relay[i].kind == sinceKind then
            out[#out + 1] = relay[i]
        end
    end
    return { src = src, count = #out, entries = out }
end)

exports['cis_libs']:RegisterCallback('cis_libstest:getRelay', 'cis_libstest:cis_test:getRelay')

exports('cis_test:resetRelay', function()
    relay = {}
    return true
end)

local function clearPending(src)
    if pendingClientIds[src] then
        pendingClientIds[src] = nil
        pendingCount = pendingCount - 1
    end
end

local function printEntry(prefix, entry)
    if not CisTestConfig.Verbose then
        return
    end
    local line = ('[%s] %-9s %s'):format(prefix, entry.status, entry.name)
    if entry.status == 'failed' then
        line = line .. ' -- ' .. tostring(entry.message)
        if entry.detail then
            line = line .. ' (' .. tostring(entry.detail) .. ')'
        end
    elseif entry.status == 'skipped' then
        line = line .. ' (' .. tostring(entry.message) .. ')'
    end
    print(line)
end

-- ------------------------------------------------------------ report writing
local function writeReport(payload)
    local name = CisTestConfig.OutputFile or ('cis-test-report-%s.json'):format(tostring(os.time()))
    local body = CisTestReport.encode(payload, '  ')
    local written = SaveResourceFile(GetCurrentResourceName(), name, body, -1)
    if written then
        print(('[cis_libstest] report written: %s/%s'):format(GetCurrentResourceName(), name))
    else
        print(('[cis_libstest] FAILED to write report %s'):format(name))
    end
    return name, body
end

-- -------------------------------------------------------------- aggregation
local function clientRows()
    local rows = {}
    for id, report in pairs(clientSubmissions) do
        for i = 1, #report do
            local e = report[i]
            rows[#rows + 1] = {
                player = id,
                name = e.name,
                status = e.status,
                message = e.message,
                detail = e.detail,
                durationMs = e.durationMs,
                values = e.values,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.player or 0) < (b.player or 0)
    end)
    return rows
end

local function totalSummary(serverReport, rows)
    local summary = {
        total = 0, passed = 0, failed = 0, skipped = 0, durationMs = 0,
        serverTotal = 0, serverFailed = 0, serverSkipped = 0,
        clientTotal = 0, clientFailed = 0, clientSkipped = 0,
        clientsReporting = 0,
    }
    for _, e in ipairs(serverReport) do
        summary.total = summary.total + 1
        summary.serverTotal = summary.serverTotal + 1
        summary[e.status] = (summary[e.status] or 0) + 1
        summary.durationMs = summary.durationMs + (e.durationMs or 0)
        if e.status == 'failed' then
            summary.serverFailed = summary.serverFailed + 1
        elseif e.status == 'skipped' then
            summary.serverSkipped = summary.serverSkipped + 1
        end
    end
    for _, e in ipairs(rows) do
        summary.total = summary.total + 1
        summary.clientTotal = summary.clientTotal + 1
        summary[e.status] = (summary[e.status] or 0) + 1
        summary.durationMs = summary.durationMs + (e.durationMs or 0)
        if e.status == 'failed' then
            summary.clientFailed = summary.clientFailed + 1
        elseif e.status == 'skipped' then
            summary.clientSkipped = summary.clientSkipped + 1
        end
    end
    for _ in pairs(clientSubmissions) do
        summary.clientsReporting = summary.clientsReporting + 1
    end
    return summary
end

-- Only runs once every invited client has reported (or the wait expired).
-- `running` tracks suite execution, `collected` tracks whether this run has
-- already produced a report; they are not the same flag.
--
-- Assigned, not `local function collect`: a `local function collect` here
-- would create a second local that shadows the forward declaration above,
-- leaving the one captured by the submit handler permanently nil.
collect = function()
    if collected then
        return
    end
    if pendingCount > 0 then
        return
    end
    collected = true

    local library = exports['cis_libs']:GetConfigSummary()
    local serverReport = reports.server or {}
    local rows = clientRows()

    local payload = CisTestReport.build({
        meta = {
            resource = 'cis_libstest',
            version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0),
            gameBuild = GetGameBuildNumber(),
            startedAt = os.time(),
            mutating = CisTestConfig.RunMutating,
            teleporting = CisTestConfig.RunTeleport,
            -- Config lives in cis_libs's own VM; read it through the export.
            framework = library and library.framework or 'UNKNOWN',
            inventory = library and library.inventory or 'UNKNOWN',
            database = library and library.database or 'UNKNOWN',
            target = library and library.target or 'UNKNOWN',
            doorlock = library and library.doorlock or 'UNKNOWN',
            syncEnabled = library and library.syncEnabled,
            databaseReady = library and library.databaseReady,
            allowListConfigured = library and library.allowListConfigured,
            libraryReady = library and library.ready,
        },
        summary = totalSummary(serverReport, rows),
        server = serverReport,
        client = rows,
    })

    local name = writeReport(payload)

    print(('[cis_libstest] ===== %d tests | %d passed | %d failed | %d skipped =====')
        :format(payload.summary.total, payload.summary.passed,
            payload.summary.failed, payload.summary.skipped))
    if payload.summary.failed > 0 then
        for _, e in ipairs(serverReport) do
            if e.status == 'failed' then
                print(('  SERVER FAILED: %s -- %s (%s)')
                    :format(e.name, tostring(e.message), tostring(e.detail)))
            end
        end
        for _, e in ipairs(rows) do
            if e.status == 'failed' then
                print(('  CLIENT FAILED [player %s]: %s -- %s')
                    :format(tostring(e.player), e.name, tostring(e.message)))
            end
        end
    end
    if payload.summary.skipped > 0 then
        print(('  %d skipped. A skip is NOT a pass -- read each reason before trusting the run.')
            :format(payload.summary.skipped))
    end
    print(('[cis_libstest] full results: %s'):format(name))

    running = false
    clientSubmissions = {}
    pendingClientIds = {}
    pendingCount = 0
end

-- ------------------------------------------------------------- client intake
RegisterNetEvent('cis_libstest:submit', function(results)
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    clearPending(src)
    if type(results) ~= 'table' then
        print(('[cis_libstest] client %d submitted a malformed report'):format(src))
        collect()
        return
    end
    clientSubmissions[src] = results
    print(('[cis_libstest] client %d reported %d tests'):format(src, #results))
    collect()
end)

-- ------------------------------------------------------------------ execution
local function runSuite()
    if running then
        print('[cis_libstest] already running')
        return
    end
    if not exports['cis_libs']:WaitReady(15000) then
        print('[cis_libstest] cis_libs did not become ready; aborting')
        return
    end

    running = true
    collected = false
    -- Must be a real report object: execute() records entries into it.
    reports = CisTestReport.new()
    clientSubmissions = {}
    pendingClientIds = {}
    pendingCount = 0
    relay = {}

    local ctx = CisTestReport.context(reports, 'server')
    local suite = CisTestServerSuite.build(ctx, CisTestConfig)

    print(('[cis_libstest] running %d server tests (mutating=%s teleport=%s)...')
        :format(#suite.tests, tostring(CisTestConfig.RunMutating), tostring(CisTestConfig.RunTeleport)))

    reports.server = CisTestRunner.execute(suite, reports, CisTestConfig, function(entry)
        printEntry('server', entry)
    end)

    local players = GetPlayers()
    if CisTestConfig.RunClientTests and #players > 0 then
        for _, id in ipairs(players) do
            local pid = tonumber(id)
            if pid then
                pendingClientIds[pid] = true
                pendingCount = pendingCount + 1
                TriggerClientEvent('cis_libstest:run', pid)
            end
        end
        print(('[cis_libstest] waiting up to %dms for %d client(s)...')
            :format(CisTestConfig.ClientWaitMs, pendingCount))
        CreateThread(function()
            Wait(CisTestConfig.ClientWaitMs)
            if pendingCount > 0 then
                print(('[cis_libstest] %d client(s) did not report in time; continuing')
                    :format(pendingCount))
            end
            collect()
        end)
    else
        collect()
    end
end

RegisterCommand('cistest', function(src)
    if src ~= 0 then
        local f = exports['cis_libs']:GetFramework()
        if not (f.HasPermission and f.HasPermission(src, 'admin')) then
            TriggerClientEvent('cis_libs:client:showNotification', src, 'admin only')
            return
        end
    end
    runSuite()
end, false)

RegisterCommand('cistest_server', function(src)
    if src ~= 0 then
        local f = exports['cis_libs']:GetFramework()
        if not (f.HasPermission and f.HasPermission(src, 'admin')) then
            return
        end
    end
    CisTestConfig.RunClientTests = false
    runSuite()
end, false)

AddEventHandler('onResourceStart', function(name)
    if name == 'cis_libs' then
        print('[cis_libstest] ready. Run /cistest from the console, or cistest as admin.')
        print(('[cis_libstest] mutating tests %s | teleport tests %s')
            :format(CisTestConfig.RunMutating and 'ENABLED' or 'disabled',
                CisTestConfig.RunTeleport and 'ON' or 'OFF'))
    end
end)
