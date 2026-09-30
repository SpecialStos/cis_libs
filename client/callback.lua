-- One event each way. Incrementing keys. Await and callback both time out.
--
-- This is the client half of the request/response channel. It carries DATA and
-- nothing else: the name, the key, and the arguments travel as net-event
-- payloads, and both of those are serialised. No Lua function can travel with
-- them, which is why every callback option in this library that a consumer
-- might want has an `*Event` twin carrying a string instead. `Cis.zones.*`
-- onEnter/onExit/inside and `Cis.player.near`'s onEnter/onExit are all
-- functions in an options table; from a consumer they arrive nil and the
-- callback simply never fires. The event forms carry a name across and the
-- server dispatches it, so they work from anywhere.
--
-- `handlers` and `pending` are process state and must exist exactly once
-- (COMPATIBILITY.md §10): a copy of this file is a second set of keys that no
-- server event will ever resolve.

local pending = CisPending.new()
local handlers = {}

local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    local handler = handlers[name]
    if not handler then
        -- Answer, do not just drop it. A silent request is indistinguishable
        -- from a lost one, and the caller would wait out the full timeout.
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'unknown')
        return
    end
    -- A handler that throws is answered as a failure rather than being allowed
    -- to abort the event thread, and the error is logged with the callback name
    -- attached so the traceback is attributable.
    local packed = table.pack(...)
    local ok, a, b, c, d, e, f = pcall(handler, table.unpack(packed, 1, packed.n))
    if not ok then
        Logging.AutoLogError(a, name)
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
        return
    end
    TriggerServerEvent('cis_libs:cb:serverRes', key, true, a, b, c, d, e, f)
end)

RegisterNetEvent('cis_libs:cb:res', function(key, ok, ...)
    local item = CisPending.take(pending, key)
    if not item then
        return
    end
    local payload = item.payload
    if payload.cb then
        payload.cb(ok, ...)
    elseif payload.promise then
        if ok then
            payload.promise:resolve({ ... })
        else
            payload.promise:reject(...)
        end
    end
end)

-- The sweep is what makes `await` bounded: without it a lost response leaves a
-- key and its promise in the table for the lifetime of the client. One pass a
-- second is coarse enough to be free and fine enough that a timeout is
-- indistinguishable from an honest slow answer.
CreateThread(function()
    while true do
        Wait(1000)
        local now = GetGameTimer()
        CisPending.sweep(pending, now, function(_, item)
            local payload = item.payload
            if payload.cb then
                payload.cb(false, 'timeout')
            elseif payload.promise then
                payload.promise:reject('timeout')
            end
        end)
    end
end)

local function startCall(name, cb, ...)
    local key = CisPending.alloc(pending, { cb = cb }, GetGameTimer() + timeoutMs())
    TriggerServerEvent('cis_libs:cb', name, key, ...)
    return key
end

-- LOCAL handlers only. The server side accepts a 'resource:export' string and
-- resolves it on demand, passing the exports table explicitly because
-- `exports[res][name]` is an unbound method and calling it bare would shift every
-- argument left by one. This side has no such dispatch: a handler that arrived
-- as a string is stored as a string and the pcall above fails on every call.
--
-- A function that arrives here at all is a function that was registered from
-- inside cis_libs, because one sent from a consumer is dropped on the way. A
-- consumer registers a client handler by having its own code listen for the
-- `*Event` names it passed to Cis.zones.* / Cis.player.near.
exports('RegisterCallback', function(name, fn)
    handlers[name] = fn
end)

exports('CallCallback', function(name, cb, ...)
    startCall(name, function(ok, ...)
        if cb then
            cb(ok, ...)
        end
    end, ...)
end)

exports('AwaitCallback', function(name, ...)
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p }, GetGameTimer() + timeoutMs())
    TriggerServerEvent('cis_libs:cb', name, key, ...)
    local packed = Citizen.Await(p)
    return table.unpack(packed)
end)

-- Legacy alias kept for the 1.x export surface. It differs from CallCallback in
-- exactly one way: it unwraps the result for the callback, so `cb` receives the
-- handler's values on success and a bare nil on failure, with no `ok` flag to
-- tell the two apart. New code should use CallCallback, where the flag is
-- explicit.
exports('TriggerLibCallback', function(name, cb, ...)
    startCall(name, function(ok, ...)
        if cb then
            if ok then
                cb(...)
            else
                cb(nil)
            end
        end
    end, ...)
end)
