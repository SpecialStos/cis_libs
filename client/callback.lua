-- One event each way. Random keys. Await and callback both time out.

local pending = CisPending.new()
local handlers = {}
-- who registered which client callback.
local callbackOwned = CisOwned.new()

local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

-- `remotes` is declared up here rather than beside its users, because the `cis_libs:cb`
local remotes = {}

-- FROM THE SERVER, OR NOT AT ALL. A net event is also reachable by a plain
-- TriggerEvent from any client resource, and the runtime sets `source` to '' for
-- that local call. Forged, `cis_libs:cb` runs any consumer's callback with the
-- forger's arguments, and `cis_libs:cb:res` answers another resource's await
-- with the forger's data. Same check as client/initialize.lua.
local function fromServer()
    local src = source
    return src ~= nil and src ~= ''
end

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    if not fromServer() then
        return
    end
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
        result = table.pack(xpcall(handler, debug.traceback, table.unpack(packed, 1, packed.n)))
    else
        -- Resolved ON CALL, not captured at registration: a restarted resource exports
        local target = exports[remote.resource]
        local fn = target and target[remote.export]
        if not CisCallable(fn) then
            TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
            return
        end
        result = table.pack(xpcall(fn, debug.traceback, target, table.unpack(packed, 1, packed.n)))
    end

    if not result[1] then
        -- A handler that throws is answered as a failure rather than being allowed to
        -- take the reply with it. xpcall + traceback, so the trace logged is the
        -- handler's own and not this dispatcher's after the stack unwound.
        Logging.AutoLogError(result[2], name)
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'error')
        return
    end
    -- `1, result.n` rather than `result.n`: entry 1 of the pack is pcall's own `true`,
    TriggerServerEvent('cis_libs:cb:serverRes', key, true,
        table.unpack(result, 2, result.n))
end)

RegisterNetEvent('cis_libs:cb:res', function(key, ok, ...)
    if not fromServer() then
        return
    end
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
-- Logged AND returned, so a caller that checks the result is told why.
local function refuse(why)
    Logging.Error(why)
    return false, why
end

exports('RegisterCallback', function(name, fn)
    if type(name) ~= 'string' or name == '' then
        return refuse('RegisterCallback needs a non-empty name')
    end
    -- who registered it, so a consumer's stop releases its own.
    local owner = GetInvokingResource() or 'cis_libs'
    -- A NAME ANOTHER RESOURCE HOLDS IS REFUSED, as zones, targets and keybinds
    -- refuse theirs. Overwriting it let any script take over a consumer's client
    -- callback and answer the server in its place. The owner may replace its
    -- own, and a name is free again once its owner stops.
    local holder = CisOwned.ownerOf(callbackOwned, 'callback', name)
    if holder and holder ~= owner then
        return refuse(('RegisterCallback: %q belongs to %s, not %s'):format(name, holder, owner))
    end
    if type(fn) == 'string' then
        local resource, export = fn:match('^([^:]+):(.+)$')
        if not resource or not export then
            return refuse(('RegisterCallback: %s must be "resource:export"'):format(name))
        end
        handlers[name] = nil
        remotes[name] = { resource = resource, export = export, owner = owner }
        CisOwned.track(callbackOwned, owner, 'callback', name)
        return true
    end
    if not CisCallable(fn) then
        return refuse(('RegisterCallback needs a function or "resource:export" for %s'):format(name))
    end
    remotes[name] = nil
    handlers[name] = fn
    CisOwned.track(callbackOwned, owner, 'callback', name)
    return true
end)

-- a consumer that stops takes its client callbacks with it, so the next call
AddEventHandler('onResourceStop', function(resource)
    -- A forged stop from another client script is ignored (shared/owned.lua).
    if not CisRealStop(resource) then
        return
    end
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(callbackOwned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'callback' then
            handlers[freed[i].id] = nil
            remotes[freed[i].id] = nil
            -- release() only LISTS; forget() is what empties the ledger.
            CisOwned.forget(callbackOwned, 'callback', freed[i].id)
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
    -- EVERY VALUE, not `local ok, a, b`: the server sends up to six, the docs
    -- promise up to six, and two named locals silently dropped the rest.
    local reply = table.pack(awaitLocal(name, ...))
    if not reply[1] then
        -- The refusal NAMES the callback.
        error(('callback %q: %s'):format(tostring(name), tostring(reply[2])), 2)
    end
    return table.unpack(reply, 2, reply.n)
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
