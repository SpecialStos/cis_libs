-- The client half of the harness: a relay, not a control channel built on the
-- library under test.
--
-- Client F8 output is invisible to whoever is driving the server, so every
-- client result is RELAYED to the server, which prints it. That is the whole
-- design, and it is deliberately plain events rather than cis_libs callbacks:
-- a harness waiting on a callback from the library it is testing cannot report
-- that the callbacks stopped working.
--
-- The client never decides whether a case passed. It runs a named case and
-- answers with the outcome; the server records it. A client that crashed
-- mid-case answers with the error rather than silently not answering, because
-- a relay that goes quiet is indistinguishable from a relay that has nothing
-- to say.

local PREFIX = 'cis_test'

local function send(name, payload)
    TriggerServerEvent(('cis_test:client_result'):format(PREFIX), name, payload)
end

-- One client case, run on demand. `fn` answers a table of { name, ok, msg, detail }.
local cases = {}

function CisTestClientCase(name, fn)
    cases[name] = fn
end

-- The server asks for a case; the client runs it inside an xpcall and answers
-- with the result. A timeout on the server side covers a client that never
-- answers at all, which is what a crash during a native call looks like.
RegisterNetEvent(('cis_test:client_run'):format(PREFIX), function(caseName)
    local fn = cases[caseName]
    if not fn then
        send(caseName, { ok = false, msg = 'no such client case', detail = caseName })
        return
    end
    local ok, result = xpcall(fn, function(m)
        return debug.traceback(tostring(m), 2)
    end)
    if not ok then
        send(caseName, { ok = false, msg = 'the case raised', detail = tostring(result) })
        return
    end
    send(caseName, result)
end)

-- Every client case the server can ask for. Reported at boot so the server's
-- suite list can be checked against what actually exists on this client --
-- a suite that lists a case no client has is a suite that will time out.
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)
    send('<ready>', { ok = true, cases = names })
end)

exports('CaseCount', function()
    local n = 0
    for _ in pairs(cases) do n = n + 1 end
    return n
end)

exports('RunCase', function(caseName)
    local fn = cases[caseName]
    if not fn then return false, 'no such client case' end
    local ok, result = xpcall(fn, function(m) return debug.traceback(tostring(m), 2) end)
    return ok, result
end)