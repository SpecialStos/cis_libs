-- One event each way. Pending keys are bound to the player they were sent to,
-- so a client can only resolve its own outstanding callbacks.
--
-- A function does not survive the exports boundary, so handlers come in two
-- forms: a local function (registered by cis_libs itself) or a
-- "resource:export" pair that is dispatched on demand.

local handlers = {}
local remotes = {}
local pending = CisPending.new()

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
        -- `self`, which is the same one-slot shift as the bracket CALL form in
        -- MEMORY.md section 3.1. Proven in-VM by
        -- `probe: how must the exports table be called?`, which gets n=2 for
        -- `fn('A','B','C')` and n=3 for `fn(self,'A','B','C')`.
        --
        -- This is why a remote handler used to receive the caller's arguments
        -- but never `src`. Passing the table explicitly is the fix, and it is
        -- exactly what the colon form does.
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
    local src = source
    if type(src) ~= 'number' or src <= 0 then
        return
    end
    if not CisRateOk(src, 'cb:' .. tostring(name), 1000, 20) then
        TriggerClientEvent('cis_libs:cb:res', src, key, false, 'rate')
        return
    end
    if not handlers[name] and not remotes[name] then
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
    local a, b, c, d, e, f = table.unpack(results, 2, results.n)
    TriggerClientEvent('cis_libs:cb:res', src, key, true, a, b, c, d, e, f)
end)

CisNetOn('cis_libs:cb:serverRes', function(src, key, ok, ...)
    local item = CisPending.take(pending, key)
    if not item then
        return
    end
    -- Keys are sequential integers, so a client could otherwise guess another
    -- pending key and resolve it with a forged payload.
    if item.payload.target ~= src then
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
        error(('Cis.callback.await: no handler for %q (%s)'):format(tostring(name), tostring(results[2])))
    end
    return table.unpack(results, 2, results.n)
end)

-- Explicit client-targeted variants. Kept separate so the local API above
-- never has to guess whether a number is data or an addressee.
exports('CallCallbackClient', function(name, target, cb, ...)
    return askClient(name, target, cb, ...)
end)

exports('AwaitCallbackClient', function(name, target, ...)
    local p = promise.new()
    local key = CisPending.alloc(pending, { promise = p, target = target }, GetGameTimer() + timeoutMs())
    TriggerClientEvent('cis_libs:cb', target, name, key, ...)
    return table.unpack(Citizen.Await(p))
end)

exports('CreateSafeCallback', function(name, cb)
    handlers[name] = cb
end)
