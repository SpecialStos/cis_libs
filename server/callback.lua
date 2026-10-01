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
-- L-C7: who registered which callback, so a consumer's stop releases its own.
-- See shared/owned.lua.
local callbackOwned = CisOwned.new()

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
    -- L-C10 · RETURN THE PACK, NOT AN UNPACK.
    --
    -- `return true, table.unpack(results, 2, results.n)` truncates at the first
    -- nil. A handler answering `nil, 'not found'` -- the single most common
    -- shape in the platform, because "no such row" is normally reported exactly
    -- that way -- lost everything after the nil, so the caller received `true,
    -- nil` with no reason at all and could not tell a missing row from a
    -- missing answer.
    --
    -- The pack travels as ONE table across this boundary and is unpacked by each
    -- caller with the count it needs. That is the only shape that survives a nil
    -- in the middle, and a nil in the middle is the normal case here, not an edge
    -- case.
    --
    -- The pcall's own `true` is STRIPPED before it travels. It sits at slot 1 of
    -- `results`, and the caller's `ok` is the separate first return -- so leaving
    -- it in would shift every handler value one slot right and deliver
    -- `cb(true, true, value)`.
    --
    -- Built by ASSIGNMENT, not by a table constructor with an unpack in it: the
    -- constructor truncates at the first nil exactly like unpack does, so the
    -- one value this whole change exists to preserve would be the one it drops.
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
        -- L-C7: the owner is read HERE, while the export is executing and
        -- GetInvokingResource() still names the consumer. Read it any later it
        -- names whatever called last, which is how a callback ends up owned by a
        -- resource that has never heard of it.
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

-- A CONSUMER THAT STOPS TAKES ITS CALLBACKS WITH IT (L-C7).
--
-- The alternative is a callback whose export no longer exists. `invoke` then
-- fails to find it, `pcall` never runs, and the caller gets `false, 'error'` --
-- which reads as "the handler has a bug in it" and sends the consumer looking at
-- their own code instead of at the resource that just stopped. Worse, the name
-- stays registered forever, so a restarted resource that registers the same
-- name is refused as a conflict against a dead handler.
--
-- Releasing it turns the next call into an honest `false, 'unknown'`: the same
-- answer as a name that was never registered, which tells a consumer their
-- wiring is wrong rather than that their handler threw.
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
        Logging.Info(('cis_libs: released %d callback(s) owned by %s'):format(#freed, tostring(resource)))
    end
end)

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    -- `source` is read into a local before anything else. Every path below can
    -- reach user code, and user code can yield; reading it first is what keeps
    -- the reply going back to the player who asked.
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    -- THE HANDLER IS CHECKED FIRST (L-C13).
    --
    -- The rate bucket is keyed on the event name, and the name arrives off the
    -- wire, so allocating the bucket before this test meant a client could grow
    -- `rates[src]` by one entry per DISTINCT name it invented -- ten thousand
    -- names, ten thousand entries, never freed, no error anywhere. A
    -- client-triggered memory leak with a denial-of-service shape.
    --
    -- Answered rather than dropped, either way: a client blocked in
    -- AwaitCallbackClient would otherwise sit until its own timeout for a name
    -- that will never resolve, and the 'unknown' reason is the actionable half
    -- of that reply.
    if not handlers[name] and not remotes[name] then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'unknown')
        return
    end
    -- 20 per second per callback NAME, not per event: a client that fans out
    -- across many distinct names gets 20 of each, and a client stuck on one
    -- name is the case that matters.
    if not CisRateOk(src, 'cb:' .. tostring(name), 1000, 20) then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'rate')
        return
    end
    local args = table.pack(...)
    local ok, results = invoke(name, src, table.unpack(args, 1, args.n))
    if not ok then
        Logging.AutoLogError(results, name)
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'error')
        return
    end
    -- Six results cross the wire and no more. A handler returning a seventh
    -- value loses it silently, so a wide return has to be packed into one table
    -- by the handler itself. Widening this is a breaking change for every client
    -- built against the current cap.
    --
    -- Unpacked FROM THE PACK WITH ITS COUNT, so a nil among the six is a real
    -- answer in that slot rather than the end of the list. `local a,b,c,d,e,f =
    -- unpack(...)` would have stopped early at `a == nil` and shifted
    -- 'not found' out of the reply entirely.
    local a, b, c, d, e, f = table.unpack(results, 1, math.min(results.n, 6))
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
    -- PACKED, with the count, on this side too. `{...}` truncates at the first
    -- nil, so a client answering `true, nil, 'x'` used to arrive as `true` and
    -- nothing else -- and the value after the nil was the whole answer.
    local packed = table.pack(...)
    if payload.cb then
        payload.cb(ok, table.unpack(packed, 1, packed.n))
    elseif payload.promise then
        if ok then
            payload.promise:resolve({ table.unpack(packed, 1, packed.n) })
        else
            -- The rejection carries the REASON, packed the same way, so a
            -- refusal names itself even when the reason sits behind a nil.
            payload.promise:reject(table.unpack(packed, 1, packed.n))
        end
    end
end, { maxHits = 40 })

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
    local ok, results = invoke(name, 0, table.unpack(packed, 1, packed.n))
    if not ok then
        Logging.AutoLogError(results, name)
        cb(false, 'error')
        return
    end
    -- The CALLER's own closure, handed every value the handler produced. It
    -- stays a closure on this side of the boundary -- that is what L-C11 is
    -- about -- so a nil in the middle of the answer is simply absent, which is
    -- exactly what a callback form wants and why it can be this simple.
    cb(true, table.unpack(results, 1, results.n))
end)

exports('AwaitCallback', function(name, ...)
    local ok, results = invoke(name, 0, ...)
    if not ok then
        -- NAME THE CALLBACK. `error('unknown')` reaches the console as
        -- "SCRIPT ERROR: @cis_libs/server/callback.lua:186: unknown", which
        -- says the library failed and says nothing about which of the dozens of
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
        -- TryAwaitCallback, which reports the same refusal as a value.
        error(('callback %q: %s'):format(tostring(name), tostring(results)), 2)
    end
    -- Unpacked FROM THE PACK, WITH ITS COUNT. `return ...` through a vararg
    -- truncates at the first nil, so a handler answering `nil, 'not found'` --
    -- the single most common shape in the platform, because "no such row" is
    -- normally reported exactly that way -- reached the caller as nothing at
    -- all. `if not rows then` could not tell a missing row from a missing
    -- answer, which is the whole reason this was worth changing.
    return table.unpack(results, 1, results.n)
end)

-- The same call, reported rather than raised (L-C10, minor).
--
-- Some callers cannot have an exception thrown through their thread: a
-- coroutine with no error boundary, a net handler whose stack is somebody
-- else's. Their only alternative today is CallCallback, which they cannot use
-- because they want a RETURN value rather than a closure -- and passing a
-- closure into a callback they also had to send across the boundary is the
-- thing L-C11 exists to stop.
--
-- So this is the await form with the refusal in the result: `ok, ...` on
-- success, `false, reason` on a refusal. `since 2.1.0` in api.lua.
exports('TryAwaitCallback', function(name, ...)
    -- Packed BEFORE the closure: `...` is not visible inside a nested function,
    -- so a closure that used it directly would be a syntax error rather than a
    -- subtle bug -- which is the better of the two, but still not something a
    -- caller should have to hit.
    local args = table.pack(...)
    local called, results = invoke(name, 0, table.unpack(args, 1, args.n))
    if not called then
        return false, ('callback %q: %s'):format(tostring(name), tostring(results))
    end
    return true, table.unpack(results, 1, results.n)
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
    -- L-C24 · THE TARGET IS VALIDATED BEFORE ANYTHING IS ALLOCATED.
    --
    -- A `target` that is not a player id used to be stored in the pending entry
    -- and handed to TriggerClientEvent, which either raised inside the exports
    -- call or addressed nobody. Either way the caller -- who is inside THIS
    -- resource, on its own thread -- got a stack trace naming a file it does not
    -- own, for a mistake it could have been told about in a return value.
    if type(target) ~= 'number' or target <= 0 then
        return false, ('callback %q: target must be a player id, got %s')
            :format(tostring(name), tostring(target))
    end
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p, target = target }, GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    -- The reply arrives PACKED, so a nil in the middle of it survives. Unpacked
    -- with the count for the same reason `invoke` returns a pack: `return ...`
    -- through a vararg truncates at the first nil.
    local settled, results = Citizen.Await(p)
    if not settled then
        return false, ('callback %q: %s'):format(tostring(name), tostring(results))
    end
    if type(results) == 'table' and results.n then
        return true, table.unpack(results, 1, results.n)
    end
    return true, results
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
