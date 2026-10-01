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
-- L-C7: who registered which client callback. See shared/owned.lua.
local callbackOwned = CisOwned.new()

local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

-- A function RETURNED from an export arrives as a callable reference table
-- carrying __cfx_functionReference, not as a bare function, so a
-- type() == 'function' check rejects a handler that works. Declared ABOVE the
-- `cis_libs:cb` handler that uses it -- a local is not in scope in the
-- expression that initialises it, so declaring it lower would resolve to a
-- global and fail at the first dispatch rather than at load.
local function isCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

-- `remotes` is declared up here rather than beside its users, because the
-- `cis_libs:cb` handler below resolves one on every call and the declaration
-- has to exist before the event can ever fire.
local remotes = {}

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    local handler = handlers[name]
    local remote = not handler and remotes[name] or nil
    if not handler and not remote then
        -- Answer, do not just drop it. A silent request is indistinguishable
        -- from a lost one, and the caller would wait out the full timeout.
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'unknown')
        return
    end

    local packed = table.pack(...)
    local ok, a, b, c, d, e, f
    if handler then
        ok, a, b, c, d, e, f = pcall(handler, table.unpack(packed, 1, packed.n))
    else
        -- Resolved ON CALL, not captured at registration: a restarted resource
        -- exports new closures, and a captured ref keeps calling the instance
        -- that no longer exists.
        --
        -- The exports table is passed EXPLICITLY. `exports[res][name]` is an
        -- unbound method, and calling it bare consumes the first argument as
        -- `self` -- shifting every remaining argument left by one and raising
        -- nothing at all. See the long note in server/callback.lua.
        local target = exports[remote.resource]
        local fn = target and target[remote.export]
        if not isCallable(fn) then
            TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
            return
        end
        ok, a, b, c, d, e, f = pcall(fn, target, table.unpack(packed, 1, packed.n))
    end

    if not ok then
        -- A handler that throws is answered as a failure rather than being
        -- allowed to abort the event thread, and the error is logged with the
        -- callback name attached so the traceback is attributable.
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
    -- PACKED, with the count, on this side too (L-C10). `{...}` truncates at the
    -- first nil, so a server answering `true, nil, 'not found'` arrived as
    -- `true` and nothing else -- and the reason after the nil WAS the answer.
    local packed = table.pack(...)
    if payload.cb then
        payload.cb(ok, table.unpack(packed, 1, packed.n))
    elseif payload.promise then
        if ok then
            payload.promise:resolve({ table.unpack(packed, 1, packed.n) })
        else
            -- A refusal rejects with its REASON, not a bare 'timeout'. A caller
            -- that catches this used to receive the string "timeout" with no
            -- indication of WHICH callback timed out, which in a resource with
            -- a dozen in flight is not an actionable error message.
            payload.promise:reject(table.unpack(packed, 1, packed.n))
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

-- LOCAL handlers, and 'resource:export' references (L-C11).
--
-- This side had no remote dispatch at all: a handler that arrived as a string
-- was stored as a string and the pcall failed on every call, so the server's
-- `RegisterCallback('x', 'res:exp')` had no client-side twin and a consumer
-- could not register a CLIENT handler by reference -- even though api.lua has
-- always declared RegisterCallback's realm as `both`.
exports('RegisterCallback', function(name, fn)
    if type(name) ~= 'string' or name == '' then
        Logging.Error('RegisterCallback needs a non-empty name')
        return false
    end
    -- L-C7: who registered it, so a consumer's stop releases its own.
    local owner = GetInvokingResource() or 'cis_libs'
    if type(fn) == 'string' then
        local resource, export = fn:match('^([^:]+):(.+)$')
        if not resource or not export then
            Logging.Error(('RegisterCallback: %s must be "resource:export"'):format(name))
            return false
        end
        handlers[name] = nil
        remotes[name] = { resource = resource, export = export, owner = owner }
        CisOwned.track(callbackOwned, owner, 'callback', name)
        return true
    end
    if not isCallable(fn) then
        Logging.Error(('RegisterCallback needs a function or "resource:export" for %s'):format(name))
        return false
    end
    remotes[name] = nil
    handlers[name] = fn
    CisOwned.track(callbackOwned, owner, 'callback', name)
    return true
end)

-- L-C7: a consumer that stops takes its client callbacks with it, so the next
-- call answers 'unknown' rather than raising against a dead export.
onClientResourceStop(function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(callbackOwned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'callback' then
            handlers[freed[i].id] = nil
            remotes[freed[i].id] = nil
        end
    end
    if #freed > 0 then
        CisLog('info', ('cis_libs: released %d client callback(s) owned by %s')
            :format(#freed, tostring(resource)))
    end
end)

exports('CallCallback', function(name, cb, ...)
    startCall(name, function(ok, ...)
        if cb then
            cb(ok, ...)
        end
    end, ...)
end)

-- The shared body of both await forms, so they cannot drift.
--
-- Answers `true, <handler results...>` or `false, <reason>` and NEVER raises.
-- `AwaitCallback` is the one that raises, and it does so by turning this
-- result into an error -- which is the whole difference between the two, and
-- having it in one place is what keeps them from disagreeing about how a reply
-- is unpacked.
local function awaitLocal(name, ...)
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p }, GetGameTimer() + timeoutMs())
    TriggerServerEvent('cis_libs:cb', name, key, ...)
    local settled, value = Citizen.Await(p)
    if settled == false then
        -- A REFUSAL, and the reason is what the server sent -- 'rate',
        -- 'unknown' or 'error'. L-C10: it used to arrive as a bare 'timeout',
        -- with no indication of WHICH callback gave up, which in a resource
        -- with a dozen in flight is not an actionable message.
        return false, value
    end
    -- The promise carries a PACKED list, so a nil in the middle of a reply
    -- survives: `true, nil, 'not found'` is a real and common answer.
    if type(value) == 'table' and value.n then
        return true, table.unpack(value, 1, value.n)
    end
    return true, value
end

exports('AwaitCallback', function(name, ...)
    local ok, a, b = awaitLocal(name, ...)
    if not ok then
        -- The refusal NAMES the callback. `error('timeout')` reaches the console
        -- as a bare "timeout" that says nothing about which of a dozen in-flight
        -- callbacks gave up.
        error(('callback %q: %s'):format(tostring(name), tostring(a)), 2)
    end
    return a, b
end)

-- The non-raising form (L-C10, minor). Same shape as the server's
-- TryAwaitCallback: `ok, ...` on success, `false, reason` on a refusal, and
-- never an exception through the caller's thread.
exports('TryAwaitCallback', function(name, ...)
    return awaitLocal(name, ...)
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
