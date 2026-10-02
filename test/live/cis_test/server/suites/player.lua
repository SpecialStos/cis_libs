-- The player tier, driven from the server.
--
-- The whole client suite runs in ONE operation on the client (snapshot, freeze,
-- run, restore, verify) and the server only ever sees the envelope. That is
-- deliberate: the plan's safety contract says the snapshot is taken before each
-- client suite and restored after, and splitting those across several round
-- trips would leave a window where the harness holds a snapshot of a player it
-- is not looking after.
--
-- SKIP IS NOT PASS. With no player connected the tier reports SKIP with a
-- reason and counts for nothing.

local pending = {}

RegisterNetEvent('cis_test:client_result', function(name, payload)
    local waiter = pending[name]
    if not waiter then
        -- Answered for a request nobody is waiting on. That is a client running
        -- a suite we did not ask for, and it is worth saying rather than
        -- dropping, because a dropped answer looks like a hung client.
        print(('[cis_test] client answered %q with nobody waiting for it'):format(tostring(name)))
        return
    end
    pending[name] = nil
    waiter(payload)
end)

-- Asks the client to run one suite and waits for the answer.
local function runClientSuite(suiteName, timeoutMs)
    local key = '<suite:' .. tostring(suiteName) .. '>'
    local answered, payload = false, nil
    pending[key] = function(p)
        answered, payload = true, p
    end

    -- The lowest server id, matching the client's own subject selection, so the
    -- server and the client cannot be talking about different people.
    local src
    for _, id in ipairs(GetPlayers()) do
        local n = tonumber(id)
        if n and (src == nil or n < src) then src = n end
    end
    if not src then return nil, 'no player connected' end

    TriggerClientEvent('cis_test:client_suite', src, suiteName)

    local deadline = GetGameTimer() + (timeoutMs or 30000)
    while GetGameTimer() < deadline do
        if answered then return payload end
        Wait(50)
    end
    pending[key] = nil
    return nil, ('the client did not answer %q within %d ms'):format(tostring(suiteName), timeoutMs or 30000)
end

-- Every client suite the server knows about, asked for in turn.
local CLIENT_SUITES = { 'zones', 'debugtext', 'points' }

CisTestRunner.Suite('player', { tier = 'player', realm = 'client', needsPlayer = true }, function(t)
    t.case('every client suite runs, and the player is left as found', function()
        local firstResult = nil

        for _, suiteName in ipairs(CLIENT_SUITES) do
            local payload, why = runClientSuite(suiteName)

            if not payload then
                t.fail(('client suite %q did not answer'):format(suiteName), tostring(why))
                goto continue
            end

            if payload.error then
                t.fail(('client suite %q returned an error'):format(suiteName),
                    tostring(payload.error))
                goto continue
            end

            -- THE RESTORE IS THE CONTRACT. A suite whose cases all passed but
            -- which left the player somewhere else is a failed run, and it is
            -- checked before the cases so it cannot be buried under them.
            t.eq(payload.restored, true,
                ('the player was restored after %q'):format(suiteName))
            if not payload.restored then
                t.fail(('the restore after %q failed'):format(suiteName),
                    tostring(payload.restoreWhy))
                goto continue
            end

            for _, c in ipairs(payload.results or {}) do
                t.eq(c.ok, true, ('%s / %s'):format(suiteName, tostring(c.name)))
                if not c.ok then
                    t.fail(('%s / %s'):format(suiteName, tostring(c.name)), tostring(c.msg))
                end
            end

            firstResult = firstResult or payload
        end

        ::continue::
        t.ok(firstResult ~= nil, 'at least one client suite answered')
    end)
end)

exports('ClientSuites', function() return CLIENT_SUITES end)