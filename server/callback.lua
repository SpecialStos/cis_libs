-- One event each way. Pending keys are bound to the player they were sent to, so a
-- client can only resolve its own outstanding callbacks.

local handlers = {}
local remotes = {}
local pending = CisPending.new()
-- who registered which callback, so a consumer's stop releases its own.
local callbackOwned = CisOwned.new()

-- 10s default, and the budget a consumer's own code is competing for: the sweep below
local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

-- How much of a client's payload is worth walking before it is refused.
local MAX_CALLBACK_ARGS = 32
local MAX_TABLE_KEYS = 256
local MAX_NESTING = 8

-- Walks a packed argument list ONCE, bounded on every axis, so the guard cannot itself
local function withinLimits(value, budget, depth)
    if type(value) ~= 'table' then
        return true
    end
    if depth > MAX_NESTING then
        return false
    end
    local seen = 0
    for _, v in pairs(value) do
        seen = seen + 1
        if seen > MAX_TABLE_KEYS then
            return false
        end
        budget.n = budget.n + 1
        if budget.n > MAX_TABLE_KEYS then
            return false
        end
        if not withinLimits(v, budget, depth + 1) then
            return false
        end
    end
    return true
end

local function payloadWithinLimits(packed, maxArgs)
    if packed.n > maxArgs then
        return false
    end
    local budget = { n = 0 }
    for i = 1, packed.n do
        if not withinLimits(packed[i], budget, 1) then
            return false
        end
    end
    return true
end

-- Measured: a function RETURNED from an export arrives as a callable reference table
local function isCallable(value)
    if type(value) == 'function' then
        return true
    end
    return type(value) == 'table' and value.__cfx_functionReference ~= nil
end

-- Returns true, <handler results...> on success, or false, <reason> on failure.
local function invoke(name, src, ...)
    local fn, self, err
    if handlers[name] then
        fn = handlers[name]
    elseif remotes[name] then
        local ref = remotes[name]
        local target = exports[ref.resource]
        fn = target and target[ref.export]
        -- MEASURED, not inferred: `exports[res][name]` is an UNBOUND method.
        self = target
        if not isCallable(fn) then
            err = ('remote handler %s:%s is not callable (got %s)')
                :format(ref.resource, ref.export, type(fn))
        end
    else
        err = 'unknown'
    end
    if not fn then
        return false, err
    end
    local results = self and table.pack(pcall(fn, self, src, ...))
        or table.pack(pcall(fn, src, ...))
    if not results[1] then
        return false, tostring(results[2])
    end
    -- RETURN THE PACK, NOT AN UNPACK.
    local out = { n = results.n - 1 }
    for i = 2, results.n do
        out[i - 1] = results[i]
    end
    return true, out
end

function CisRegisterCallback(name, handler)
    if type(name) ~= 'string' or name == '' then
        Logging.Error('RegisterCallback needs a non-empty name')
        return false
    end
    if type(handler) == 'string' then
        local resource, export = handler:match('^([^:]+):(.+)$')
        if not resource or not export then
            Logging.Error(('RegisterCallback: %s must be "resource:export"'):format(name))
            return false
        end
        remotes[name] = { resource = resource, export = export }
        -- the owner is read HERE, while the export is executing and
        CisOwned.track(callbackOwned, GetInvokingResource() or 'cis_libs', 'callback', name)
        return true
    end
    if not isCallable(handler) then
        Logging.Error(('RegisterCallback needs a function or "resource:export" for %s'):format(name))
        return false
    end
    handlers[name] = handler
    CisOwned.track(callbackOwned, GetInvokingResource() or 'cis_libs', 'callback', name)
    return true
end

-- A CONSUMER THAT STOPS TAKES ITS CALLBACKS WITH IT ().
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    -- Dropped WITHOUT invoking them.
    local doomed = {}
    for key, item in pairs(pending.items) do
        if item.payload.owner == resource then
            doomed[#doomed + 1] = key
        end
    end
    for i = 1, #doomed do
        pending.items[doomed[i]] = nil
    end

    local freed = CisOwned.release(callbackOwned, resource)
    for i = 1, #freed do
        if freed[i].kind == 'callback' then
            handlers[freed[i].id] = nil
            remotes[freed[i].id] = nil
        end
    end
    if #freed > 0 then
        Logging.Info(('cis_libs: released %d callback(s) owned by %s'):format(#freed, tostring(resource)))
    end
    if #doomed > 0 then
        Logging.Info(('cis_libs: dropped %d pending callback(s) owned by %s')
            :format(#doomed, tostring(resource)))
    end
end)

--- A PLAYER WHO DROPS DOES NOT LEAVE THE SERVER WAITING FOR THEM.
AddEventHandler('playerDropped', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    local doomed = {}
    for key, item in pairs(pending.items) do
        if item.payload.target == src then
            doomed[#doomed + 1] = key
        end
    end
    for i = 1, #doomed do
        local item = pending.items[doomed[i]]
        pending.items[doomed[i]] = nil
        local payload = item and item.payload
        if payload and payload.cb then
            -- The CALLER may still be alive -- a resource waiting on a player who just
            payload.cb(false, 'player dropped')
        end
    end
    if #doomed > 0 then
        Logging.Info(('cis_libs: dropped %d pending callback(s) for player %d who left')
            :format(#doomed, src))
    end
end)

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    -- `source` is read into a local before anything else.
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    -- THE HANDLER IS CHECKED FIRST ().
    if not handlers[name] and not remotes[name] then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'unknown')
        return
    end
    -- 20 per second per callback NAME, not per event: a client that fans out across
    if not CisRateOk(src, 'cb:' .. tostring(name), 1000, 20) then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'rate')
        return
    end
    local args = table.pack(...)
    -- THE PAYLOAD IS ALREADY DESERIALIZED BY THE TIME THIS RUNS, and no native can make
    if not payloadWithinLimits(args, MAX_CALLBACK_ARGS) then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'too large')
        return
    end
    local ok, results = invoke(name, src, table.unpack(args, 1, args.n))
    if not ok then
        Logging.AutoLogError(results, name)
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'error')
        return
    end
    -- Six results cross the wire and no more.
    local a, b, c, d, e, f = table.unpack(results, 1, math.min(results.n, 6))
    TriggerClientEvent('cis_libs:cb:res', src, key, true, a, b, c, d, e, f)
end)

CisNetOn('cis_libs:cb:serverRes', function(src, key, ok, ...)
    -- Ownership is checked BEFORE the entry is consumed.
    local peeked = CisPending.peek(pending, key)
    if not peeked then
        return
    end
    if peeked.payload.target ~= src then
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
    -- PACKED, with the count, on this side too.
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
            -- The rejection carries the REASON, not the pack.
            payload.promise:reject(out[1])
        end
    end
end, { maxHits = 40 })

-- Sweeps expired pending keys.
CreateThread(CisLoopGuard.Run('server.callback.sweep', 1000, function()
    CisPending.sweep(pending, GetGameTimer(), function(_, item)
        local payload = item.payload
        if payload.cb then
            payload.cb(false, 'timeout')
        elseif payload.promise then
            payload.promise:reject('timeout')
        end
    end)
end))

local function askClient(name, target, cb, ...)
    if type(target) ~= 'number' or target <= 0 then
        Logging.Error('Cis.callback.callClient needs a numeric target server id')
        if cb then
            cb(false, 'bad target')
        end
        return
    end
    -- `target` is stored in the payload because the reply handler compares it against
    local key = CisPending.alloc(pending,
        { cb = cb, target = target, owner = GetInvokingResource(), sentAt = GetGameTimer() },
        GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    return key
end

exports('RegisterCallback', CisRegisterCallback)

-- Local dispatch only. Any first argument is passed through to the handler as data; a
exports('CallCallback', function(name, cb, ...)
    if type(cb) ~= 'function' then
        Logging.Error('Cis.callback.call needs a callback function')
        return
    end
    if not handlers[name] and not remotes[name] then
        cb(false, 'unknown')
        return
    end
    local packed = table.pack(...)
    local ok, results = invoke(name, 0, table.unpack(packed, 1, packed.n))
    if not ok then
        Logging.AutoLogError(results, name)
        cb(false, 'error')
        return
    end
    -- The CALLER's own closure, handed every value the handler produced.
    cb(true, table.unpack(results, 1, results.n))
end)

exports('AwaitCallback', function(name, ...)
    local ok, results = invoke(name, 0, ...)
    if not ok then
        -- NAME THE CALLBACK. `error('unknown')` reaches the console as "SCRIPT ERROR:
        error(('callback %q: %s'):format(tostring(name), tostring(results)), 2)
    end
    -- Unpacked FROM THE PACK, WITH ITS COUNT.
    return table.unpack(results, 1, results.n)
end)

-- The same call, reported rather than raised (minor).
exports('TryAwaitCallback', function(name, ...)
    -- Packed BEFORE the closure: `...` is not visible inside a nested function, so a
    local args = table.pack(...)
    local called, results = invoke(name, 0, table.unpack(args, 1, args.n))
    if not called then
        return false, ('callback %q: %s'):format(tostring(name), tostring(results))
    end
    return true, table.unpack(results, 1, results.n)
end)

-- Explicit client-targeted variants.
exports('CallCallbackClient', function(name, target, cb, ...)
    return askClient(name, target, cb, ...)
end)

-- Parks the calling coroutine on a promise rather than polling.
exports('AwaitCallbackClient', function(name, target, ...)
    -- THE TARGET IS VALIDATED BEFORE ANYTHING IS ALLOCATED.
    if type(target) ~= 'number' or target <= 0 then
        return false, ('callback %q: target must be a player id, got %s')
            :format(tostring(name), tostring(target))
    end
    -- `GetPlayerName` answering nil is this library's own "that player is not here"
    if not GetPlayerName(target) then
        return false, ('callback %q: player %d is not connected'):format(tostring(name), target)
    end
    local p = promise.new()
    local key = CisPending.alloc(pending,
        { promise = p, target = target, owner = GetInvokingResource(), sentAt = GetGameTimer() },
        GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    -- C1 · CITIZEN.AWAIT RETURNS ONE VALUE, AND A REJECTION THROWS.
    local okCall, results = pcall(Citizen.Await, p)
    if not okCall then
        return false, ('callback %q: %s'):format(tostring(name), tostring(results))
    end
    -- The reply arrives PACKED, so a nil in the middle of it survives.
    if type(results) == 'table' and results.n then
        return true, table.unpack(results, 1, results.n)
    end
    return true, results
end)

-- Pending callbacks are the leak the plan's lifecycle cases exist to catch, and they
CisDiagnostics.Register('server', 'pendingCallbacks', function()
    local total, byOwner = 0, {}
    for _, item in pairs(pending.items) do
        total = total + 1
        local owner = item.payload.owner or '<none>'
        byOwner[owner] = (byOwner[owner] or 0) + 1
    end
    return { toClient = total, total = total, byOwner = byOwner }
end)
