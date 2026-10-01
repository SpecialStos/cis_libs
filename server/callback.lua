-- One event each way. Pending keys are bound to the player they were sent to,
-- so a client can only resolve its own outstanding callbacks.
--
-- A function does not survive the exports boundary, so handlers come in two
-- forms: a local function (registered by cis_libs itself) or a
-- "resource:export" pair that is dispatched on demand.
--
-- Every handler's FIRST parameter is always `src` (0 for a server-side call),
-- and the caller's arguments follow. That is the invariant the invoke() below
-- exists to protect: a remote handler reached through the wrong calling form
-- loses `src` without raising, so the bug shows up as a handler that works
-- perfectly except it never knows who asked.

local handlers = {}
local remotes = {}
local pending = CisPending.new()

-- 10s default, and the budget a consumer's own code is competing for: the
-- sweep below cannot fire before this, and a client that has already given up
-- never learns the answer.
local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

-- Measured: a function RETURNED from an export arrives as a callable reference
-- table carrying __cfx_functionReference, not as a bare function. A
-- type() == 'function' check therefore rejects a handler that works, so both
-- shapes are accepted.
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
        -- Calling it without the exports table consumes the first argument as
        -- `self`, shifting every remaining argument left by one. Measured in-VM
        -- against a three-argument export: the bracket form `fn('A','B','C')`
        -- reports n=2 with A and B as the arguments, while
        -- `fn(self,'A','B','C')` reports n=3. Nothing errors; the handler just
        -- runs with a string in `self` and one argument missing.
        --
        -- This is why a remote handler used to receive the caller's arguments
        -- but never `src`. Passing the table explicitly is the fix, and it is
        -- exactly what the colon form does -- do not "simplify" it back.
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
    return true, table.unpack(results, 2, results.n)
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
        return true
    end
    if not isCallable(handler) then
        Logging.Error(('RegisterCallback needs a function or "resource:export" for %s'):format(name))
        return false
    end
    handlers[name] = handler
    return true
end

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    -- `source` is read into a local before anything else. Every path below can
    -- reach user code, and user code can yield; reading it first is what keeps
    -- the reply going back to the player who asked.
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    -- 20 per second per callback NAME, not per event: a client that fans out
    -- across many distinct names gets 20 of each, and a client stuck on one
    -- name is the case that matters.
    if not CisRateOk(src, 'cb:' .. tostring(name), 1000, 20) then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'rate')
        return
    end
    if not handlers[name] and not remotes[name] then
        -- Answered rather than dropped. A client blocked in AwaitCallbackClient
        -- would otherwise sit until its own timeout for a name that will never
        -- resolve; the 'unknown' reason is the actionable half of that reply.
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'unknown')
        return
    end
    local packed = table.pack(...)
    local results = table.pack(invoke(name, src, table.unpack(packed, 1, packed.n)))
    if not results[1] then
        Logging.AutoLogError(results[2], name)
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'error')
        return
    end
    -- Six results cross the wire and no more. A handler returning a seventh
    -- value loses it silently, so a wide return has to be packed into one
    -- table by the handler itself. Widening this is a breaking change for
    -- every client built against the current cap.
    local a, b, c, d, e, f = table.unpack(results, 2, results.n)
    TriggerClientEvent('cis_libs:cb:res', src, key, true, a, b, c, d, e, f)
end)

CisNetOn('cis_libs:cb:serverRes', function(src, key, ok, ...)
    -- Ownership is checked BEFORE the entry is consumed. Keys are sequential
    -- integers, so a client can name any key it likes, and the take used to
    -- happen first: a forged key removed the victim's pending entry, the
    -- ownership test then correctly rejected it, and the victim was left with no
    -- callback AND no pending entry for the sweep to time out -- so the call
    -- never resolved and never reported. One client could silently hang another
    -- client's request by guessing a number.
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

-- Sweeps expired pending keys. 1s, not tighter: the shortest deadline a client
-- can be holding is Config.CallbackTimeout (10s by default), so a 1s sweep can
-- overshoot a timeout by at most a second, while a tighter one would wake the
-- scheduler hundreds of times per second for no observable gain. A client that
-- gave up has already moved on; this is what stops a dead client's entry from
-- living in the table forever.
CreateThread(function()
    while true do
        Wait(1000)
        CisPending.sweep(pending, GetGameTimer(), function(_, item)
            local payload = item.payload
            if payload.cb then
                payload.cb(false, 'timeout')
            elseif payload.promise then
                payload.promise:reject('timeout')
            end
        end)
    end
end)

local function askClient(name, target, cb, ...)
    if type(target) ~= 'number' or target <= 0 then
        Logging.Error('Cis.callback.callClient needs a numeric target server id')
        if cb then
            cb(false, 'bad target')
        end
        return
    end
    -- `target` is stored in the payload because the reply handler compares it
    -- against the src that answered. The key alone is not a secret: it is a
    -- sequential integer and any client can read another client's key out of
    -- its own event traffic.
    local key = CisPending.alloc(pending, { cb = cb, target = target }, GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    return key
end

exports('RegisterCallback', CisRegisterCallback)

-- Local dispatch only. Any first argument is passed through to the handler as
-- data; a number is never reinterpreted as a target server id.
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
    local results = table.pack(invoke(name, 0, table.unpack(packed, 1, packed.n)))
    if not results[1] then
        Logging.AutoLogError(results[2], name)
        cb(false, 'error')
        return
    end
    cb(true, table.unpack(results, 2, results.n))
end)

exports('AwaitCallback', function(name, ...)
    local results = table.pack(invoke(name, 0, ...))
    if not results[1] then
        -- Name the callback. `error('unknown')` reaches the console as
        -- "SCRIPT ERROR: @cis_libs/server/callback.lua:186: unknown", which
        -- says the library failed and nothing about which of the dozens of
        -- registered callbacks did. A refusal that cannot be acted on is the
        -- ambiguity the whole `false, '<reason>'` convention exists to remove.
        --
        -- Raising, rather than returning `false`, is the same decision. The
        -- await form is synchronous and has one result slot, so a false would
        -- be indistinguishable from a handler that legitimately returned
        -- false -- the caller would carry on as though the value were real.
        -- This is the one place in the library where a refusal is loud, and it
        -- is loud on purpose: only a mis-typed callback name reaches it, and
        -- every other callback failure is a runtime error in a handler rather
        -- than a "no handler" case. Callers that must not raise use
        -- CallCallback, which reports the same refusal through the callback.
        error(('Cis.callback.await: no handler for %q (%s)'):format(tostring(name), tostring(results[2])))
    end
    return table.unpack(results, 2, results.n)
end)

-- Explicit client-targeted variants. Kept separate so the local API above
-- never has to guess whether a number is data or an addressee.
exports('CallCallbackClient', function(name, target, cb, ...)
    return askClient(name, target, cb, ...)
end)

-- Parks the calling coroutine on a promise rather than polling. The bound is
-- still the sweep above, not this: Citizen.Await has no deadline of its own, so
-- a client that never replies and never trips the timeout would park the
-- coroutine for the life of the resource.
exports('AwaitCallbackClient', function(name, target, ...)
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p, target = target }, GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    return table.unpack(Citizen.Await(p))
end)

-- Deliberately unchecked, and the only registration path that is. It exists
-- for callers that register a placeholder before the real handler exists (a
-- resource wiring up order, or an ESX-style adapter that fills the function
-- in later). RegisterCallback's validation would reject the nil and force
-- those callers to re-register; the cost is that a name registered here with
-- no handler behind it fails at dispatch time instead, with 'error' rather
-- than 'unknown'. Deprecated: prefer RegisterCallback.
exports('CreateSafeCallback', function(name, cb)
    handlers[name] = cb
end)
