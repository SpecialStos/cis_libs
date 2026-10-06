-- 8.5 soak. Minutes of zones, points, sync records, callbacks and net events
-- together. Samples BOTH VMs every minute. Writes soak_latest.json each minute
-- so a crash still leaves the samples that ran.
--
-- Pass: after collectgarbage at minute 1 and at the end, memory growth under
-- 512 KB on each VM, error counters do not rise, soak-owned counts do not drift.
-- Never stores player names, identifiers, coords or IPs.

CisTestSoak = {}

local abort = false
local running = false

local function writeJson(path, obj)
    local body = CisTestJson.encode(obj)
    local ok, err = pcall(SaveResourceFile, GetCurrentResourceName(), path, body, -1)
    if not ok then
        print(('[cis_test] soak could not write %s: %s'):format(path, tostring(err)))
        return false
    end
    return true
end

local function snapDiag(d)
    if type(d) ~= 'table' then
        return { missing = true }
    end
    return {
        realm = d.realm,
        uptimeMs = d.uptimeMs,
        memoryKb = d.memoryKb,
        counters = d.counters,
        probes = d.probes,
        timings = d.timings,
    }
end

local function lowestPlayer()
    local src
    for _, id in ipairs(GetPlayers()) do
        local n = tonumber(id)
        if n and (src == nil or n < src) then src = n end
    end
    return src
end

local function withClientWait(eventKey, timeoutMs, triggerFn)
    local answered, payload = false, nil
    CisTestSoak._waiters = CisTestSoak._waiters or {}
    CisTestSoak._waiters[eventKey] = function(p)
        if answered then return end
        answered, payload = true, p
    end
    triggerFn()
    local deadline = GetGameTimer() + (timeoutMs or 10000)
    while GetGameTimer() < deadline do
        if answered then
            CisTestSoak._waiters[eventKey] = nil
            return payload
        end
        Wait(50)
    end
    CisTestSoak._waiters[eventKey] = nil
    return nil
end

RegisterNetEvent('cis_test:soak_client_ready', function(payload)
    local w = CisTestSoak._waiters and CisTestSoak._waiters['ready']
    if w then w(payload) end
end)

RegisterNetEvent('cis_test:soak_client_sample', function(payload)
    local w = CisTestSoak._waiters and CisTestSoak._waiters['sample']
    if w then w(payload) end
end)

local function countersOf(snap)
    return (snap and snap.diagnostics and snap.diagnostics.counters) or {}
end

local function memoryOf(snap)
    return snap and snap.diagnostics and snap.diagnostics.memoryKb
end

local function driftLine(label, a, b)
    if a == b then return nil end
    return ('%s %s -> %s'):format(label, tostring(a), tostring(b))
end

local function evaluate(samples, firstMin, lastMin)
    local first, last
    for i = 1, #samples do
        if samples[i].minute == firstMin then first = samples[i] end
        if samples[i].minute == lastMin then last = samples[i] end
    end
    if not first or not last then
        return { ok = false, why = ('missing sample at minute %s or %s'):format(tostring(firstMin), tostring(lastMin)) }
    end
    local reasons = {}
    local function checkVm(name, a, b)
        local ma, mb = memoryOf(a[name]), memoryOf(b[name])
        local delta
        if type(ma) == 'number' and type(mb) == 'number' then
            delta = mb - ma
            if delta > 512 then
                reasons[#reasons + 1] = ('%s memoryKb %+0.1f (budget 512)'):format(name, delta)
            end
        else
            reasons[#reasons + 1] = ('%s memoryKb missing'):format(name)
        end
        local ca, cb = countersOf(a[name]), countersOf(b[name])
        for _, key in ipairs({ 'errors', 'warnings', 'tickErrors', 'zoneErrors', 'callbackErrors' }) do
            local x, y = ca[key] or 0, cb[key] or 0
            if y > x then
                reasons[#reasons + 1] = ('%s counter %s %s -> %s'):format(name, key, tostring(x), tostring(y))
            end
        end
        return delta
    end
    local serverDelta = checkVm('server', first, last)
    local clientDelta = checkVm('client', first, last)
    if first.clientMissing or last.clientMissing then
        reasons[#reasons + 1] = 'a collected sample has no client payload'
    end
    local sa = first.server and first.server.diagnostics and first.server.diagnostics.probes or {}
    local sb = last.server and last.server.diagnostics and last.server.diagnostics.probes or {}
    local recA = sa.syncRecords and sa.syncRecords.dynamic
    local recB = sb.syncRecords and sb.syncRecords.dynamic
    local d = driftLine('syncRecords.dynamic', recA, recB)
    if d then reasons[#reasons + 1] = d end
    return {
        ok = #reasons == 0,
        why = (#reasons == 0) and 'pass' or table.concat(reasons, '; '),
        serverMemoryDeltaKb = serverDelta,
        clientMemoryDeltaKb = clientDelta,
        fromMinute = firstMin,
        toMinute = lastMin,
    }
end

function CisTestSoak.Running()
    return running == true
end

function CisTestSoak.Abort()
    abort = true
end

function CisTestSoak.Start(minutes)
    minutes = tonumber(minutes) or 30
    minutes = math.floor(minutes)
    if minutes < 5 then minutes = 5 end
    if minutes > 120 then minutes = 120 end
    if running then
        print('[cis_test] soak already running; cis_test abort first')
        return false
    end
    local src = lowestPlayer()
    if not src then
        print('[cis_test] soak needs a connected player for client samples')
        return false
    end

    abort = false
    running = true
    local runId = 'soak-' .. os.date('!%Y%m%d-%H%M%S')
    print(('[cis_test] soak %d min starting (%s)'):format(minutes, runId))

    CreateThread(function()
        local syncIds, zoneIds = {}, {}
        local samples = {}
        local missedClient = 0

        local function persist(extra)
            local body = {
                run = runId,
                commit = CisTestRunner.Commit and CisTestRunner.Commit() or '?',
                players = CisTestRunner.PlayerCount and CisTestRunner.PlayerCount() or 0,
                minutesPlanned = minutes,
                missedClient = missedClient,
                samples = samples,
                done = extra and extra.done or false,
                verdict30 = extra and extra.verdict30 or nil,
                verdict = extra and extra.verdict or nil,
            }
            writeJson('soak_latest.json', body)
            writeJson(('soak_%s.json'):format(runId), body)
        end

        local function cleanup()
            for i = 1, #syncIds do
                pcall(function() exports['cis_libs']:SyncRemove(syncIds[i]) end)
                if i % 25 == 0 then Wait(0) end
            end
            for i = 1, #zoneIds do
                pcall(function() exports['cis_libs']:ServerZoneRemove(zoneIds[i]) end)
                if i % 25 == 0 then Wait(0) end
            end
            local p = lowestPlayer()
            if p then
                TriggerClientEvent('cis_test:soak_stop', p)
            end
        end

        local okStart, errStart = xpcall(function()
            for i = 1, 200 do
                local id = exports['cis_libs']:SyncCreate('prop', {
                    id = 'soak-sync-' .. i,
                    model = 'prop_roadcone02a',
                    coords = { x = 200.0 + (i % 20) * 12.0, y = 200.0 + math.floor(i / 20) * 12.0, z = 30.0 },
                    networked = false,
                })
                if id then syncIds[#syncIds + 1] = id end
                if i % 25 == 0 then Wait(0) end
            end
            for i = 1, 50 do
                local id = exports['cis_libs']:ServerZoneBox({
                    x = 4000.0 + (i % 10) * 20.0,
                    y = 4000.0 + math.floor(i / 10) * 20.0,
                    z = 40.0,
                }, 4.0)
                if type(id) == 'number' then zoneIds[#zoneIds + 1] = id end
                if i % 25 == 0 then Wait(0) end
            end

            src = lowestPlayer()
            if not src then error('player left during soak setup') end
            local ready = withClientWait('ready', 15000, function()
                TriggerClientEvent('cis_test:soak_start', src)
            end)
            if not ready then
                print('[cis_test] soak: client did not ack start (client soak script missing?). Continuing with server samples.')
            end

            local function takeSample(minute)
                local doCollect = (minute == 1 or minute == 30 or minute == minutes)
                local server = { diagnostics = snapDiag(exports['cis_libs']:GetDiagnostics({ collect = doCollect })), collected = doCollect }
                src = lowestPlayer()
                local client, clientMissing = nil, true
                if src then
                    local payload = withClientWait('sample', 10000, function()
                        TriggerClientEvent('cis_test:soak_tick', src, minute, doCollect)
                    end)
                    if payload then
                        client = {
                            diagnostics = snapDiag(payload.diagnostics),
                            zoneDebug = payload.zoneDebug,
                            pointsDebug = payload.pointsDebug,
                            collected = doCollect,
                        }
                        clientMissing = false
                    end
                end
                if clientMissing then missedClient = missedClient + 1 end
                samples[#samples + 1] = {
                    minute = minute,
                    at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
                    players = CisTestRunner.PlayerCount and CisTestRunner.PlayerCount() or 0,
                    server = server,
                    client = client,
                    clientMissing = clientMissing,
                }
                persist({})
                print(('[cis_test] soak minute %d/%d serverMem=%s clientMem=%s clientMissing=%s')
                    :format(minute, minutes,
                        tostring(memoryOf(server)),
                        tostring(client and memoryOf(client)),
                        tostring(clientMissing)))
            end

            takeSample(0)
            for minute = 1, minutes do
                if abort then break end
                Wait(60000)
                if abort then break end
                takeSample(minute)
            end
        end, function(err)
            return tostring(err)
        end)

        if not okStart then
            print('[cis_test] soak raised: ' .. tostring(errStart))
        end

        local lastMin = 0
        for i = 1, #samples do
            if samples[i].minute > lastMin then lastMin = samples[i].minute end
        end
        local extra = { done = true }
        if lastMin >= 30 then
            extra.verdict30 = evaluate(samples, 1, 30)
        end
        extra.verdict = evaluate(samples, 1, lastMin)
        extra.aborted = abort == true
        persist(extra)
        print(('[cis_test] soak finished minutes=%s verdict=%s (%s)')
            :format(tostring(lastMin), tostring(extra.verdict and extra.verdict.ok),
                extra.verdict and extra.verdict.why or ''))

        cleanup()
        running = false
        abort = false
    end)
    return true
end
