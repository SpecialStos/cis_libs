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

-- How much of a client's payload is worth walking before it is refused.
--
-- A handler is a function somebody wrote expecting a couple of arguments. A
-- callback argument that is a thousand-wide table is not a payload, it is a
-- denial of service that happens to arrive in a shape the rate limiter cannot
-- see. These are deliberately generous: the point is to catch the absurd, not
-- to enforce a contract on ordinary callers.
local MAX_CALLBACK_ARGS = 32
local MAX_TABLE_KEYS = 256
local MAX_NESTING = 8

-- Walks a packed argument list ONCE, bounded on every axis, so the guard cannot
-- itself become the thing that hangs.
--
-- The budget is counted across the whole payload rather than per argument, so
-- "thirty small arguments each holding a hundred keys" is refused too -- a limit
-- that could be spent in slices is not a limit.
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
    -- AND THE PENDING ENTRIES THAT RESOURCE CREATED.
    --
    -- Dropped WITHOUT invoking them. Its Lua VM is already gone, so calling the
    -- closure would raise inside cis_libs's own handler over a caller that no
    -- longer exists -- and the closure's `cb` or `promise` belongs to that dead
    -- resource anyway. The entries go; the waiters do not get an answer, because
    -- there is nobody left to receive one.
    --
    -- Collected and removed FIRST, then reported, for the reason
    -- `CisPending.sweep` documents: the store must be consistent before any
    -- other code can look at it.
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
---
--- Every server-to-client await aimed at this src is rejected now, with a reason
--- that says what happened, rather than being left to the one-second sweep and
--- then to the full CallbackTimeout. Ten seconds is not a long time to a person,
--- but it is ten seconds of a live coroutine per outstanding call, and the
--- caller was told nothing at all while it lasted.
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
            -- The CALLER may still be alive -- a resource waiting on a player who
            -- just left is exactly the normal case -- so this one IS answered,
            -- and answered with the reason rather than the generic 'timeout'.
            payload.cb(false, 'player dropped')
        end
    end
    if #doomed > 0 then
        Logging.Info(('cis_libs: dropped %d pending callback(s) for player %d who left')
            :format(#doomed, src))
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
    -- THE PAYLOAD IS ALREADY DESERIALIZED BY THE TIME THIS RUNS, and no native
    -- can make that otherwise.
    --
    -- The obvious tool is `GetEventData`, and it cannot do this job. It is
    -- `BOOL GET_EVENT_DATA(int group, int index, int* data, int size)` -- it
    -- reads the RAGE script event queue (`SCRIPT_EVENT_QUEUE_AI` /
    -- `_NETWORK`, the game's internal scripted-event system), it is client-only
    -- with no server apiset, it takes the buffer size as an INPUT rather than
    -- reporting one, and it returns success rather than a size. It has nothing to
    -- do with the Lua net-event path and no way to report a payload length.
    --
    -- So this is a REJECT-AFTER-DESERIALIZE guard, and the honest description of
    -- what it buys is: it stops a client from spending the server's CPU in a
    -- handler, not from spending its memory in the deserializer. Both matter,
    -- and only the second one is outside Lua's reach -- FiveM's own limits are
    -- the defence there.
    --
    -- What is left to check is depth and breadth, which are what a hostile
    -- payload actually abuses: a deeply nested table and a very wide one are
    -- cheap to send and expensive to walk. Measured by walking the pack ONCE,
    -- bounded, so the guard itself cannot become the denial of service.
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
        -- BUILT BY ASSIGNMENT, not `{ table.unpack(...) }`. A table constructor
        -- truncates at the first nil exactly like unpack does -- which is why
        -- `invoke` above builds its pack the long way -- and this line did it
        -- anyway, so a reply of `true, nil, 'not found'` was resolved as a table
        -- holding only `true` and the reason was gone before the promise was
        -- touched.
        local out = { n = packed.n }
        for i = 1, packed.n do
            out[i] = packed[i]
        end
        if ok then
            payload.promise:resolve(out)
        else
            -- The rejection carries the REASON, not the pack. A client refuses
            -- with one value ('rate', 'unknown', 'error', 'timeout'), and
            -- `Citizen.Await` signals a rejection by raising that single value
            -- -- so a pack would reach the caller as "table: 0x...", which is
            -- not something anyone can log.
            payload.promise:reject(out[1])
        end
    end
end, { maxHits = 40 })

-- Sweeps expired pending keys. 1s, not tighter: the shortest deadline a client
-- can be holding is Config.CallbackTimeout (10s by default), so a 1s sweep can
-- overshoot a timeout by at most a second, while a tighter one would wake the
-- scheduler hundreds of times per second for no observable gain. A client that
-- gave up has already moved on; this is what stops a dead client's entry from
-- living in the table forever.
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
    -- `target` is stored in the payload because the reply handler compares it
    -- against the src that answered. The key alone is not a secret: it is a
    -- sequential integer and any client can read another client's key out of
    -- its own event traffic.
    -- `owner` IS RECORDED AT ALLOCATION, not looked up later. A pending entry
    -- has two ends -- the resource waiting, and the player who owes the answer --
    -- and the resource end is the only one that can go away silently. Without an
    -- owner on the entry, a stopped resource's entries are indistinguishable
    -- from anyone else's, so the sweep below has nothing to sweep.
    local key = CisPending.alloc(pending,
        { cb = cb, target = target, owner = GetInvokingResource() },
        GetGameTimer() + timeoutMs())
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
    -- AND A PLAUSIBLE ID THAT NOBODY HOLDS IS REFUSED HERE TOO.
    --
    -- `GetPlayerName` answering nil is this library's own "that player is not
    -- here" test (server/security.lua, server/proxy.lua), and this is the third
    -- place that needs it. Before the check, an await for a player who has
    -- already left allocated an entry, fired an event at nobody, and parked the
    -- caller until the full CallbackTimeout -- ten seconds of a thread doing
    -- nothing, for a caller who already knew the answer.
    if not GetPlayerName(target) then
        return false, ('callback %q: player %d is not connected'):format(tostring(name), target)
    end
    local p = promise.new()
    local key = CisPending.alloc(pending,
        { promise = p, target = target, owner = GetInvokingResource() },
        GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    -- C1 · CITIZEN.AWAIT RETURNS ONE VALUE, AND A REJECTION THROWS.
    --
    -- Verified against citizenfx/fivem
    -- `data/shared/citizen/scripting/lua/scheduler.lua`:
    --
    --     function Citizen.Await(promise)
    --         ...
    --         if promise.state == 2 or promise.state == 4 then
    --             error(promise.value, 2)
    --         end
    --         return promise.value
    --     end
    --
    -- This used to read `local settled, results = Citizen.Await(p)`, so `settled`
    -- was the PACKED reply -- a table -- and `results` was nil. A table is
    -- truthy, so the refusal branch could never run, and the branch that
    -- unpacked the pack could never run either. Every awaitClient call answered
    -- `true, nil`.
    --
    -- That is the whole of the damage, and it is worse than losing a value: the
    -- server could not tell "the client answered nil" from "the client REFUSED"
    -- from "the client never answered at all". A timeout came back as a
    -- successful empty result -- a caller with a full timeout ahead of it,
    -- holding an empty table, treating it as real.
    --
    -- So the pack comes back as ONE value, and the rejection is CAUGHT rather
    -- than read, because `Await` signals it by RAISING. `deferred:reject` is
    -- handed the reason string below, so the error object is that string and
    -- the refusal reaches the caller as `false, '<name>: <reason>'`.
    local okCall, results = pcall(Citizen.Await, p)
    if not okCall then
        return false, ('callback %q: %s'):format(tostring(name), tostring(results))
    end
    -- The reply arrives PACKED, so a nil in the middle of it survives. Unpacked
    -- with the count for the same reason `invoke` returns a pack: `return ...`
    -- through a vararg truncates at the first nil.
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

-- Pending callbacks are the leak the plan's lifecycle cases exist to catch, and
-- they leak in one direction more easily than the other: a server-to-client
-- await whose player leaves has no owner left to expire it.
--
-- GROUPED BY OWNER, for the same reason `syncRecords` is grouped by owner: a
-- total cannot tell "released its own" from "released everything", and those
-- are different answers to the question the lifecycle tier asks. Before entries
-- carried an owner at all, so there was nothing to group by.
CisDiagnostics.Register('server', 'pendingCallbacks', function()
    local total, byOwner = 0, {}
    for _, item in pairs(pending.items) do
        total = total + 1
        local owner = item.payload.owner or '<none>'
        byOwner[owner] = (byOwner[owner] or 0) + 1
    end
    return { toClient = total, total = total, byOwner = byOwner }
end)
