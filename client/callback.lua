-- One event each way. Incrementing keys. Await and callback both time out.

local pending = CisPending.new()
local handlers = {}
-- who registered which client callback.
local callbackOwned = CisOwned.new()

local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

-- A function RETURNED from an export arrives as a callable reference table carrying
local function isCallable(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

-- `remotes` is declared up here rather than beside its users, because the `cis_libs:cb`
local remotes = {}

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    local handler = handlers[name]
    local remote = not handler and remotes[name] or nil
    if not handler and not remote then
        -- Answer, do not just drop it.
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'unknown')
        return
    end

    local packed = table.pack(...)
    -- PACKED, NOT SIX NAMED LOCALS.
    local result
    if handler then
        result = table.pack(pcall(handler, table.unpack(packed, 1, packed.n)))
    else
        -- Resolved ON CALL, not captured at registration: a restarted resource exports
        local target = exports[remote.resource]
        local fn = target and target[remote.export]
        if not isCallable(fn) then
            TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
            return
        end
        result = table.pack(pcall(fn, target, table.unpack(packed, 1, packed.n)))
    end

    if not result[1] then
        -- A handler that throws is answered as a failure rather than being allowed to
        Logging.AutoLogError(result[2], name)
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
        return
    end
    -- `1, result.n` rather than `result.n`: entry 1 of the pack is pcall's own `true`,
    TriggerServerEvent('cis_libs:cb:serverRes', key, true,
        table.unpack(result, 2, result.n))
end)

RegisterNetEvent('cis_libs:cb:res', function(key, ok, ...)
    local item = CisPending.take(pending, key)
    if not item then
        return
    end
    local payload = item.payload
    if CisTiming and type(payload.sentAt) == 'number' then
        CisTiming.observe('callbackRtt', GetGameTimer() - payload.sentAt)
    end
    -- PACKED, with the count, on this side too ().
    local packed = table.pack(...)
    if payload.cb then
        payload.cb(ok, table.unpack(packed, 1, packed.n))
    elseif payload.promise then
        -- BUILT BY ASSIGNMENT, not `{ table.unpack(...) }`.
        local out = { n = packed.n }
        for i = 1, packed.n do
            out[i] = packed[i]
        end
        if ok then
            payload.promise:resolve(out)
        else
            -- A refusal rejects with its REASON, not a bare 'timeout'.
            payload.promise:reject(out[1])
        end
    end
end)

-- The sweep is what makes `await` bounded: without it a lost response leaves a key and
CreateThread(CisLoopGuard.Run('client.callback.sweep', 1000, function()
    CisPending.sweep(pending, GetGameTimer(), function(_, item)
        local payload = item.payload
        if payload.cb then
            payload.cb(false, 'timeout')
        elseif payload.promise then
            payload.promise:reject('timeout')
        end
    end)
end))

local function startCall(name, cb, ...)
    local key = CisPending.alloc(pending, { cb = cb, sentAt = GetGameTimer() }, GetGameTimer() + timeoutMs())
    TriggerServerEvent('cis_libs:cb', name, key, ...)
    return key
end

-- LOCAL handlers, and 'resource:export' references ().
exports('RegisterCallback', function(name, fn)
    if type(name) ~= 'string' or name == '' then
        Logging.Error('RegisterCallback needs a non-empty name')
        return false
    end
    -- who registered it, so a consumer's stop releases its own.
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

-- a consumer that stops takes its client callbacks with it, so the next call
AddEventHandler('onResourceStop', function(resource)
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
local function awaitLocal(name, ...)
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p, sentAt = GetGameTimer() }, GetGameTimer() + timeoutMs())
    TriggerServerEvent('cis_libs:cb', name, key, ...)
    -- C1 · CITIZEN.AWAIT RETURNS ONE VALUE, AND A REJECTION THROWS.
    local okCall, value = pcall(Citizen.Await, p)
    if not okCall then
        -- A REFUSAL, and the reason is what the server sent -- 'rate', 'unknown' or
        return false, tostring(value)
    end
    -- The promise carries a PACKED list, so a nil in the middle of a reply survives:
    if type(value) == 'table' and value.n then
        return true, table.unpack(value, 1, value.n)
    end
    return true, value
end

exports('AwaitCallback', function(name, ...)
    local ok, a, b = awaitLocal(name, ...)
    if not ok then
        -- The refusal NAMES the callback.
        error(('callback %q: %s'):format(tostring(name), tostring(a)), 2)
    end
    return a, b
end)

-- The non-raising form (minor).
exports('TryAwaitCallback', function(name, ...)
    return awaitLocal(name, ...)
end)

-- Legacy alias kept for the 1.x export surface.
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

CisDiagnostics.Register('client', 'pendingCallbacks', function()
    return { toServer = CisPending.count(pending), total = CisPending.count(pending) }
end)
