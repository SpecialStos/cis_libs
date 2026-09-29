-- One event each way. Incrementing keys. Await and callback both time out.

local pending = CisPending.new()
local handlers = {}

local function timeoutMs()
    return (Config and Config.CallbackTimeout) or 10000
end

RegisterNetEvent('cis_libs:cb', function(name, key, ...)
    local handler = handlers[name]
    if not handler then
        TriggerServerEvent('cis_libs:cb:serverRes', key, false, 'unknown')
        return
    end
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
