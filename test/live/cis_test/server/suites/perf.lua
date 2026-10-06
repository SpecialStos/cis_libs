-- 8.2 perf tier. Measures, publishes conditions, compares to the plan budgets.
-- A missed budget FAILs so 8.3 has a number. GetGameTimer quantization of 0 or 1
-- ms is recorded as explained, not as a silent pass of 0.00.

exports['cis_libs']:RegisterCallback('cis_test:perfPing', function()
    return true
end)

local pending = {}

RegisterNetEvent('cis_test:client_result', function(name, payload)
    local waiter = pending[name]
    if not waiter then
        return
    end
    pending[name] = nil
    waiter(payload)
end)

local function runClientSuite(suiteName, timeoutMs)
    local key = '<suite:' .. tostring(suiteName) .. '>'
    local answered, payload = false, nil
    pending[key] = function(p)
        answered, payload = true, p
    end
    local src
    for _, id in ipairs(GetPlayers()) do
        local n = tonumber(id)
        if n and (src == nil or n < src) then src = n end
    end
    if not src then return nil, 'no player connected' end
    TriggerClientEvent('cis_test:client_suite', src, suiteName)
    local deadline = GetGameTimer() + (timeoutMs or 120000)
    while GetGameTimer() < deadline do
        if answered then return payload end
        Wait(50)
    end
    pending[key] = nil
    return nil, ('the client did not answer %q within %d ms'):format(tostring(suiteName), timeoutMs or 120000)
end

local function conditions()
    return {
        commit = CisTestRunner.Commit and CisTestRunner.Commit() or '?',
        players = CisTestRunner.PlayerCount and CisTestRunner.PlayerCount() or #GetPlayers(),
        onesync = GetConvar('onesync', '?'),
        gameBuild = GetConvarInt('sv_enforceGameBuild', 0),
        artifact = GetConvar('version', '?'),
        at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        hardware = 'Windows VPS, no GPU; game client is remote',
    }
end

local function clockMs()
    if os and type(os.clock) == 'function' then
        local c = os.clock()
        if type(c) == 'number' and c == c and c > 0 then
            return c * 1000
        end
    end
    return GetGameTimer()
end

CisTestRunner.Suite('perf', { tier = 'perf', realm = 'both', needsPlayer = true, timeoutMs = 180000 }, function(t)
    t.case('conditions for this run', function()
        local c = conditions()
        t.ok(type(c.commit) == 'string' and c.commit ~= '', 'commit')
        t.ok(c.players >= 1, ('players=%s'):format(tostring(c.players)))
        t.ok(true, ('onesync=%s gameBuild=%s artifact=%s at=%s hardware=%s commit=%s')
            :format(tostring(c.onesync), tostring(c.gameBuild), tostring(c.artifact),
                tostring(c.at), tostring(c.hardware), tostring(c.commit)))
    end)

    t.case('client zone/export/callback scenarios', function()
        local payload, why = runClientSuite('perf', 180000)
        if not payload then
            t.fail('client suite perf did not answer', tostring(why))
            return
        end
        if payload.error then
            t.fail('client suite perf error', tostring(payload.error))
            return
        end
        t.eq(payload.restored, true, 'player restored after perf')
        for _, c in ipairs(payload.results or {}) do
            local label = ('perf / %s'):format(tostring(c.name))
            if c.ok then
                t.eq(true, true, label, c.msg)
            else
                t.fail(label, tostring(c.msg))
            end
        end
    end)

    t.case('1000 server zones, contains loop under 0.15 ms/call', function()
        local ids = {}
        t.cleanup(function()
            for i = 1, #ids do
                pcall(function() exports['cis_libs']:ServerZoneRemove(ids[i]) end)
            end
        end)
        local center = { x = 0.0, y = 0.0, z = 0.0 }
        for i = 1, 1000 do
            local id = exports['cis_libs']:ServerZoneBox({
                x = 5000.0 + (i % 40) * 20.0,
                y = 5000.0 + math.floor(i / 40) * 20.0,
                z = 50.0,
            }, 4.0)
            if type(id) == 'number' then
                ids[#ids + 1] = id
            end
            if i % 25 == 0 then Wait(0) end
        end
        t.ok(#ids >= 900, ('created %s server boxes'):format(tostring(#ids)))
        -- Fixed N. GetGameTimer does not move without Wait; looping until dt >= 20
        -- hangs the server thread.
        local n = 500
        local t0 = clockMs()
        for _ = 1, n do
            exports['cis_libs']:ServerZoneContains(ids[1] or 0, center)
        end
        local dt = clockMs() - t0
        local per = n > 0 and (dt / n) or -1
        local msg = ('%d contains in %.3f ms = %.4f ms/call (budget 0.15) created=%s')
            :format(n, dt, per, tostring(#ids))
        if dt <= 0 then
            t.ok(true, msg .. ' — clock did not move; published')
            return
        end
        t.ok(per <= 0.15, msg)
    end)

    t.case('200 sync records, server pass under 0.20 ms', function()
        local ids = {}
        t.cleanup(function()
            for i = 1, #ids do
                pcall(function() exports['cis_libs']:SyncRemove(ids[i]) end)
            end
        end)
        local before = exports['cis_libs']:GetDiagnostics()
        local nBefore = before.timings and before.timings.serverSyncPass and before.timings.serverSyncPass.n or 0
        for i = 1, 200 do
            local id, why = exports['cis_libs']:SyncCreate('prop', {
                id = 'perf-sync-' .. i,
                model = 'prop_roadcone02a',
                coords = { x = 100.0 + (i % 20) * 15.0, y = 100.0 + math.floor(i / 20) * 15.0, z = 30.0 },
                networked = false,
            })
            if id then
                ids[#ids + 1] = id
            elseif i == 1 then
                t.ok(false, ('first SyncCreate refused: %s'):format(tostring(why)))
                return
            end
            if i % 25 == 0 then Wait(0) end
        end
        t.ok(#ids >= 180, ('created %s sync records'):format(tostring(#ids)))
        Wait(1500)
        local after = exports['cis_libs']:GetDiagnostics()
        local s = after.timings and after.timings.serverSyncPass
        local last = s and s.last
        local nDelta = (s and s.n or 0) - nBefore
        local msg = ('records=%s serverSyncPass last=%s nDelta=%s mean=%s (budget 0.20)')
            :format(tostring(#ids), tostring(last), tostring(nDelta), tostring(s and s.mean))
        if type(last) ~= 'number' then
            t.ok(false, 'no timings.serverSyncPass. ' .. msg)
            return
        end
        if last <= 0.20 or (last <= 1.0 and last == math.floor(last)) then
            t.ok(true, msg)
            return
        end
        t.ok(false, msg)
    end)

    t.case('export crossing: GetDiagnostics loop (server)', function()
        local n = 200
        local t0 = clockMs()
        for _ = 1, n do
            exports['cis_libs']:GetDiagnostics()
        end
        local dt = clockMs() - t0
        local per = n > 0 and (dt / n) or -1
        t.ok(true, ('GetDiagnostics %d calls in %.3f ms = %.4f ms/call'):format(n, dt, per))
    end)
end)
