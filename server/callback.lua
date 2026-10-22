-- One event each way. Pending keys are bound to the player they were sent to, so a
-- client can only resolve its own outstanding callbacks.

-- name -> { fn = callable } or { resource, export }, plus its options:
-- { remote, ace, schema, maxStringLen }. ONE table, not one per handler kind: a
-- name registered as a function and later as "resource:export" used to keep the
-- function, which `invoke` checks first, so the later registration never ran.
local callbacks = {}
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
-- be the expensive part. Strings are measured too, keys and values both: a 4 MB
-- string is one "key" to every other bound here and costs every consumer that logs it.
local function withinLimits(value, budget, depth, maxLen)
    local kind = type(value)
    if kind == 'string' then
        return #value <= maxLen
    end
    if kind ~= 'table' then
        return true
    end
    if depth > MAX_NESTING then
        return false
    end
    local seen = 0
    for k, v in pairs(value) do
        seen = seen + 1
        if seen > MAX_TABLE_KEYS then
            return false
        end
        budget.n = budget.n + 1
        if budget.n > MAX_TABLE_KEYS then
            return false
        end
        if not withinLimits(k, budget, depth + 1, maxLen) then
            return false
        end
        if not withinLimits(v, budget, depth + 1, maxLen) then
            return false
        end
    end
    return true
end

local function payloadWithinLimits(packed, maxArgs, maxLen)
    if packed.n > maxArgs then
        return false
    end
    local budget = { n = 0 }
    for i = 1, packed.n do
        if not withinLimits(packed[i], budget, 1, maxLen) then
            return false
        end
    end
    return true
end

-- Returns true, <pack of handler results> on success, or false, <reason>, <trapped
-- error or nil> on failure. Run under xpcall so the trapped error carries the
-- HANDLER's file and line, not this one's.
local function invoke(name, src, ...)
    local entry = callbacks[name]
    if not entry then
        return false, 'unknown'
    end
    local fn, self = entry.fn, nil
    if not fn then
        local target = exports[entry.resource]
        fn = target and target[entry.export]
        -- MEASURED, not inferred: `exports[res][name]` is an UNBOUND method.
        self = target
        if not CisCallable(fn) then
            return false, ('remote handler %s:%s is not callable (got %s)')
                :format(entry.resource, entry.export, type(fn))
        end
    end
    local trap = Logging.Trap or debug.traceback
    local results
    if self then
        results = table.pack(xpcall(fn, trap, self, src, ...))
    else
        results = table.pack(xpcall(fn, trap, src, ...))
    end
    if not results[1] then
        return false, tostring(results[2]), results[2]
    end
    -- RETURN THE PACK, NOT AN UNPACK.
    local out = { n = results.n - 1 }
    for i = 2, results.n do
        out[i - 1] = results[i]
    end
    return true, out
end

-- The options a registration may carry, checked before anything is stored, so a
-- typo is a refusal that names itself rather than a callback quietly unguarded.
local function readOptions(name, opts)
    if opts == nil then
        return { remote = true }
    end
    if type(opts) ~= 'table' then
        return nil, ('RegisterCallback %s: opts must be a table, got %s'):format(name, type(opts))
    end
    if opts.remote ~= nil and type(opts.remote) ~= 'boolean' then
        return nil, ('RegisterCallback %s: opts.remote must be true or false, got %s')
            :format(name, type(opts.remote))
    end
    if opts.ace ~= nil and (type(opts.ace) ~= 'string' or opts.ace == '') then
        return nil, ("RegisterCallback %s: opts.ace must be an ACE object string like 'cis.admin', got %s")
            :format(name, type(opts.ace))
    end
    if opts.schema ~= nil and type(opts.schema) ~= 'table' then
        return nil, ('RegisterCallback %s: opts.schema must be a map of field -> { type, min, max, maxLen, optional }, got %s')
            :format(name, type(opts.schema))
    end
    local maxLen = opts.maxStringLen
    if maxLen ~= nil and (type(maxLen) ~= 'number' or maxLen ~= maxLen or maxLen < 1) then
        return nil, ('RegisterCallback %s: opts.maxStringLen must be a positive number, got %s')
            :format(name, tostring(maxLen))
    end
    return {
        -- REMOTE BY DEFAULT, because 1.0.0 had no other kind and every consumer
        -- registered so far expects its clients to reach it.
        remote = opts.remote ~= false,
        ace = opts.ace,
        schema = opts.schema,
        maxStringLen = maxLen and math.floor(maxLen) or nil,
    }
end

function CisRegisterCallback(name, handler, opts)
    if type(name) ~= 'string' or name == '' then
        Logging.Error('RegisterCallback needs a non-empty name')
        return false, 'RegisterCallback needs a non-empty name'
    end
    local options, why = readOptions(name, opts)
    if not options then
        Logging.Error(why)
        return false, why
    end
    local entry
    if type(handler) == 'string' then
        local resource, export = handler:match('^([^:]+):(.+)$')
        if not resource or not export then
            why = ('RegisterCallback: %s must be "resource:export"'):format(name)
            Logging.Error(why)
            return false, why
        end
        entry = { resource = resource, export = export }
    elseif CisCallable(handler) then
        -- A function, or a function another resource handed over, which arrives as
        -- a callable reference table. Either way it is OWNED by the invoker below
        -- and released on its stop.
        entry = { fn = handler }
    else
        why = ('RegisterCallback needs a function or "resource:export" for %s'):format(name)
        Logging.Error(why)
        return false, why
    end
    entry.remote = options.remote
    entry.ace = options.ace
    entry.schema = options.schema
    entry.maxStringLen = options.maxStringLen
    -- REPLACES whatever held the name, function or reference, and drops the
    -- reference to it -- a funcref kept alive here is a closure in another
    -- resource that is never collected.
    callbacks[name] = entry
    -- the owner is read HERE, while the export is executing.
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
            callbacks[freed[i].id] = nil
            -- release() only LISTS what the owner held; forget() is what stops the
            -- ledger holding it for the life of the server.
            CisOwned.forget(callbackOwned, 'callback', freed[i].id)
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

-- Per player: requests this window across EVERY name, and handler coroutines still
-- running. Keyed by src, cleared on drop.
local budgets = {}
local inflight = {}

--- A PLAYER WHO DROPS DOES NOT LEAVE THE SERVER WAITING FOR THEM.
AddEventHandler('playerDropped', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    budgets[src] = nil
    inflight[src] = nil
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
        -- The CALLER may still be alive -- a resource waiting on a player who just
        -- left. A callback is told; a promise is REJECTED, or the coroutine parked
        -- on it in AwaitCallbackClient waits forever. Each under pcall: one caller
        -- whose callback raises must not leave the rest unanswered.
        if payload and payload.cb then
            local ok, err = pcall(payload.cb, false, 'player dropped')
            if not ok then
                Logging.AutoLogError(err, 'playerDropped')
            end
        elseif payload and payload.promise then
            payload.promise:reject('player dropped')
        end
    end
    if #doomed > 0 then
        Logging.Info(('cis_libs: dropped %d pending callback(s) for player %d who left')
            :format(#doomed, src))
    end
end)

local function answer(src, key, ...)
    TriggerClientEvent('cis_libs:cb:res', src, key, ...)
end

-- The player's budget across every callback name. A separate counter from the
-- per-name limiter on purpose: it is ONE slot per player whatever the client
-- sends, so it can sit in front of the name lookup without a made-up name ever
-- allocating anything.
local function playerBudgetOk(src, limits)
    local now = GetGameTimer()
    local budget = budgets[src]
    if not budget then
        budget = { started = now, hits = 0 }
        budgets[src] = budget
    elseif now - budget.started >= limits.windowMs then
        budget.started = now
        budget.hits = 0
    end
    budget.hits = budget.hits + 1
    if budget.hits > limits.perPlayer then
        CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
        return false
    end
    return true
end

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    -- `source` is read into a local before anything else.
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    local limits = CisCallbackLimits()
    -- THE PLAYER'S BUDGET IS CHECKED FIRST, before the name is even looked at: a
    -- client spraying made-up names used to be answered 'unknown' as fast as it
    -- could send them.
    if not playerBudgetOk(src, limits) then
        answer(src, key, false, 'rate')
        return
    end
    -- THEN THE HANDLER (). A local-only callback answers exactly like a
    -- missing one, so a client cannot even learn that the name exists.
    local entry = callbacks[name]
    if not entry or not entry.remote then
        answer(src, key, false, 'unknown')
        return
    end
    -- Per NAME, so one busy callback does not starve the rest of the budget.
    if not CisRateOk(src, 'cb:' .. tostring(name), limits.windowMs, limits.perName) then
        answer(src, key, false, 'rate')
        return
    end
    if entry.ace and not IsPrincipalAceAllowed(('player.%d'):format(src), entry.ace) then
        answer(src, key, false, 'denied')
        return
    end
    local args = table.pack(...)
    -- THE PAYLOAD IS ALREADY DESERIALIZED BY THE TIME THIS RUNS, and no native can make
    if not payloadWithinLimits(args, MAX_CALLBACK_ARGS, entry.maxStringLen or limits.maxStringLen) then
        answer(src, key, false, 'too large')
        return
    end
    if entry.schema then
        local schemaOk, schemaWhy = CisCheckNetSchema(entry.schema, args[1])
        if not schemaOk then
            CisDiagnostics.Inc(CisDiagnostics.NAMES.NET_SCHEMA_REFUSED)
            CisSecurityReport(src, ('bad callback payload %s: %s'):format(tostring(name), tostring(schemaWhy)))
            answer(src, key, false, 'bad payload')
            return
        end
    end
    -- IN FLIGHT. A handler that awaits a database keeps this event's coroutine
    -- alive, and a client could otherwise park any number of them at once. The
    -- slot is captured, not re-read, so a player who drops and whose id is reused
    -- mid-call cannot have the newcomer's count decremented.
    local slot = inflight[src]
    if not slot then
        slot = { n = 0 }
        inflight[src] = slot
    end
    if slot.n >= limits.maxInFlight then
        answer(src, key, false, 'busy')
        return
    end
    slot.n = slot.n + 1
    local ok, results, trapped = invoke(name, src, table.unpack(args, 1, args.n))
    slot.n = slot.n - 1
    if slot.n <= 0 and inflight[src] == slot then
        inflight[src] = nil
    end
    if not ok then
        Logging.AutoLogError(trapped or results, name)
        answer(src, key, false, 'error')
        return
    end
    -- Six results cross the wire and no more.
    local a, b, c, d, e, f = table.unpack(results, 1, math.min(results.n, 6))
    answer(src, key, true, a, b, c, d, e, f)
end)

-- The reply to a server->client callback. NOT rate-limited per event: every reply
-- that counts consumes a pending entry this server created for this client, so the
-- server's own requests bound it, and the old fixed 40-a-second cap dropped real
-- replies for a busy UI. A reply nobody asked this client for costs one table read.
RegisterNetEvent('cis_libs:cb:serverRes', function(key, ok, ...)
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
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
    -- The reply is client data like any request, and is bounded the same way. The
    -- caller is still answered -- with a refusal -- rather than left to time out.
    if not payloadWithinLimits(packed, MAX_CALLBACK_ARGS, CisCallbackLimits().maxStringLen) then
        ok = false
        packed = { n = 1, 'too large' }
    end
    if payload.cb then
        local cbOk, err = pcall(payload.cb, ok, table.unpack(packed, 1, packed.n))
        if not cbOk then
            Logging.AutoLogError(err, 'cis_libs:cb:serverRes')
        end
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
end)

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
        if CisCallable(cb) then
            cb(false, 'bad target')
        end
        return
    end
    if cb ~= nil and not CisCallable(cb) then
        cb = nil
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
    -- CisCallable, not type() == 'function': a closure passed in by ANOTHER resource
    -- arrives as a callable reference table, and refusing it refused every consumer.
    if not CisCallable(cb) then
        Logging.Error('Cis.callback.call needs a callback function')
        return
    end
    if not callbacks[name] then
        cb(false, 'unknown')
        return
    end
    local packed = table.pack(...)
    local ok, results, trapped = invoke(name, 0, table.unpack(packed, 1, packed.n))
    if not ok then
        Logging.AutoLogError(trapped or results, name)
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

-- What is registered, and what the ownership ledger still holds. The two must
-- agree: a ledger entry with no callback behind it is a stop that was not swept.
CisDiagnostics.Register('server', 'callbacks', function()
    local registered, localOnly = 0, 0
    for _, entry in pairs(callbacks) do
        registered = registered + 1
        if not entry.remote then
            localOnly = localOnly + 1
        end
    end
    local inFlight = 0
    for _, slot in pairs(inflight) do
        inFlight = inFlight + slot.n
    end
    return {
        registered = registered,
        localOnly = localOnly,
        owned = CisOwned.count(callbackOwned),
        inFlight = inFlight,
    }
end)
