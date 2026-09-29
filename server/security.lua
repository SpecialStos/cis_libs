local rates = {}
local authorized

local function rebuildAuthorized()
    authorized = nil
    local list = Security and Security.AuthorizedResources
    if type(list) ~= 'table' or #list == 0 then
        return
    end
    authorized = {}
    for i = 1, #list do
        authorized[list[i]] = true
    end
end

rebuildAuthorized()

local function invokingAllowed()
    if not authorized then
        return true
    end
    local resource = GetInvokingResource()
    if not resource or resource == GetCurrentResourceName() then
        return true
    end
    return authorized[resource] == true
end

function CisInvokingAllowed()
    return invokingAllowed()
end

local function rateOk(src, name, windowMs, maxHits)
    windowMs = windowMs or 1000
    maxHits = maxHits or 8
    local now = GetGameTimer()
    rates[src] = rates[src] or {}
    local bucket = rates[src][name]
    if not bucket or now - bucket.started >= windowMs then
        rates[src][name] = { started = now, hits = 1 }
        return true
    end
    bucket.hits = bucket.hits + 1
    return bucket.hits <= maxHits
end

function CisRateOk(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end

function CisNetOn(name, fn, opts)
    opts = opts or {}
    RegisterNetEvent(name, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        if not rateOk(src, name, opts.windowMs, opts.maxHits) then
            CisLog('warn', ('rate limited %s from %s'):format(name, src), 'cheating')
            return
        end
        local ok, err = pcall(fn, src, ...)
        if not ok then
            Logging.AutoLogError(err, name)
        end
    end)
end

local DEFAULT_DROP_MESSAGE = 'cis_libs: Kicked. If you believe this is a mistake, contact the server owner.'

function CisSecurityReport(src, reason)
    CisLog('warn', ('security report src=%s reason=%s'):format(tostring(src), tostring(reason)), 'cheating')
    if type(src) ~= 'number' or src <= 0 then
        return false
    end
    if GetPlayerName(src) == nil then
        return false
    end
    -- Security.DropPlayer may be a boolean or a custom function(src, reason).
    local handler = Security and Security.DropPlayer
    if type(handler) == 'function' then
        local ok, err = pcall(handler, src, reason)
        if not ok then
            Logging.AutoLogError(err, 'Security.DropPlayer')
            return false
        end
        return true
    end
    if handler then
        DropPlayer(src, DEFAULT_DROP_MESSAGE)
        return true
    end
    return false
end

exports('SecureNetOn', function(name, fn)
    CisNetOn(name, fn)
end)

-- Exposed so a companion resource can ask "would a mutation from me be
-- allowed?" before attempting one, instead of guessing from the config.
exports('InvokingAllowed', function()
    return invokingAllowed()
end)

exports('RateOk', function(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end)

exports('SecurityReport', CisSecurityReport)

exports('GetLibsPrefix', function()
    return (Security and Security.EventPrefix) or 'cis_libs'
end)

AddEventHandler('playerDropped', function()
    rates[source] = nil
end)
