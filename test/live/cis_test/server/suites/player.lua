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

-- How long ONE client suite gets before the harness calls it unanswered.
-- Generous on purpose: the subject is a real person's game client, and an
-- unfocused FiveM client throttles its own frame loop.
local SUITE_TIMEOUT_MS = 60000

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
--
-- 'exports' is FIRST on purpose. It only asks whether the client can see the
-- exports the suites below are about to call, so when it fails the rest report
-- failures against code that never ran -- which is how a zone P0 was reported
-- twice in this project. The cost is a suite that cannot be wrong about
-- anything except reachability.
local CLIENT_SUITES = { 'exports', 'zones', 'debugtext', 'points', 'stage3', 'synchygiene', 'ui', 'cache' }

CisTestRunner.Suite('player', { tier = 'player', realm = 'client', needsPlayer = true }, function(t)
    t.case('every client suite runs, and the player is left as found', function()
        local firstResult = nil

        for _, suiteName in ipairs(CLIENT_SUITES) do
            -- ONE RETRY, and a longer budget, because the subject is a real
            -- person's game client and it is often not the focused window.
            --
            -- A FiveM client that is not in the foreground throttles its own
            -- frame loop, so a suite that answers in 9 s on a focused client can
            -- take 35 s on an unfocused one -- and 30 s of patience produced a
            -- "did not answer" against a client that was working the whole time.
            -- That is a support ticket written by the harness about the player.
            --
            -- The retry is bounded at one so a genuinely dead client still
            -- fails, and it fails with the SECOND timeout rather than the first,
            -- so the message says how long the client actually had.
            local payload, why = runClientSuite(suiteName, SUITE_TIMEOUT_MS)
            if not payload then
                payload, why = runClientSuite(suiteName, SUITE_TIMEOUT_MS)
                if payload then
                    t.ok(true, ('client suite %q answered on the second attempt '
                        .. 'after the first timed out at %d ms'):format(suiteName,
                            SUITE_TIMEOUT_MS))
                end
            end

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
                local label = ('%s / %s'):format(suiteName, tostring(c.name))
                -- Failures are reported through t.fail with the CLIENT's own
                -- message as the detail. Asserting through t.eq instead loses it:
                -- eq's detail is "expected true, got false", which is the same
                -- for every client case and says nothing about which one or why.
                -- The note goes through on the SUCCESS path too. That is the whole
                -- point: a client case answers nil -- 'nothing spawned and nothing
                -- was proved' -- when the client cannot stream the model, and that
                -- explanation used to be discarded here, which made a run that
                -- proved nothing indistinguishable from one that proved everything.
                if c.ok then
                    t.eq(true, true, label, c.msg)
                else
                    t.fail(label, tostring(c.msg))
                end
            end

            firstResult = firstResult or payload
        end

        ::continue::
        t.ok(firstResult ~= nil, 'at least one client suite answered')
    end)
end)

-- A RAW SYNC PAYLOAD, delivered to one client on purpose.
--
-- The server refuses to SEND a malformed record any more -- that is 4.9 working
-- -- so the only way to ask the client what it does when one arrives is to send
-- one. The client suite cannot do that itself: `TriggerEvent` does not cross a
-- resource boundary, so a record raised from cis_test never reached the
-- handler in cis_libs and every refusal case passed without anything arriving.
--
-- HARNESS plumbing. It adds nothing to cis_libs and is not part of any contract.
RegisterNetEvent('cis_test:rawSync', function(record)
    TriggerClientEvent('cis_libs:client:syncUpsert', source, record)
end)

-- And the matching remove, so a successful spawn is cleaned up through the same
-- route rather than by a local call that would not reach cis_libs either.
RegisterNetEvent('cis_test:rawSyncRemove', function(key)
    TriggerClientEvent('cis_libs:client:syncRemove', source, key)
end)


-- WHAT THE CLIENT LOGGED. Printed, not stored: the point is that a person
-- driving this from a machine cannot see F8, and a client-side refusal that
-- says nothing is a refusal nobody can act on.
RegisterNetEvent('cis_test:client_log', function(level, message)
    print(('[cis_test:client] %s %s'):format(tostring(level), tostring(message)))
end)


exports('ClientSuites', function() return CLIENT_SUITES end)