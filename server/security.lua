-- Net-event gate, rate limiter, and the door/sync allow-list.

local rates = {}
-- How many buckets each src is holding, kept as a COUNTER beside the map.
local rateCounts = {}
local authorized

-- Postures for the "AuthorizedResources is empty" case.
local posture

-- An empty table is treated as "not configured", the same as nil.
local function configuredList()
    local list = Security and Security.AuthorizedResources
    if type(list) ~= 'table' or #list == 0 then
        return nil
    end
    return list
end

-- THE ESCAPE HATCH, AND IT IS OPT-IN AND VALIDATED.
local function allowAnyResource()
    return Security and Security.AllowAnyResource == true
end


local function reportRestrictive(reason)
    print('[cis_libs] SECURITY: door and sync mutations are REFUSED for every resource except cis_libs.')
    print(('  %s'):format(reason))
    print('  Security.AuthorizedResources is empty, and an empty list is always restrictive:')
    print('  an empty list used to mean "any server-side resource may add, break and rewrite doors".')
    print('  Name the resources that mutate doors, e.g.')
    print('      Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" }')
    print('  A resource can ask first: exports["cis_libs"]:InvokingAllowed().')
    print('  To restore the old permissive behaviour for every resource instead, set')
    print('      Security.AllowAnyResource = true')
end

-- One decision, applied once. Idempotent because SetConfig calls this again on every
local function applyPosture(next, reason)
    if posture == next then
        return
    end
    posture = next
    if next == 'restrictive' then
        reportRestrictive(reason)
    elseif next == 'permissive' then
        print('[cis_libs] SECURITY: Security.AllowAnyResource is TRUE -- every server-side')
        print('  resource may mutate doors and sync records. This is the 1.0.0 escape hatch')
        print('  and it is deliberately loud. To turn it off:')
        print('      Security.AllowAnyResource = false')
        print('  To allow only the resources you name instead:')
        print('      Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" }')
    end
end

-- Decides the allow-list. Two cases, and both are DEFINITE:
local function rebuildAuthorized()
    authorized = nil
    local list = configuredList()
    if list then
        authorized = {}
        for i = 1, #list do
            authorized[list[i]] = true
        end
        posture = 'configured'
        return
    end
    -- A NAMED LIST STILL WINS over AllowAnyResource.
    if allowAnyResource() then
        applyPosture('permissive', 'Security.AllowAnyResource is set')
        return
    end
    applyPosture('restrictive', 'Security.AuthorizedResources is empty')
    -- An empty, non-nil table denies every foreign caller.
    authorized = {}
end

rebuildAuthorized()

-- Rebuild the allow-list, for SetConfig.
function CisSecurityRebuild()
    rebuildAuthorized()
end

-- NO DEFERRED PROBE ANYMORE. This thread used to wait up to 30 seconds for a


-- The one place a mutation asks "may I?".
local function invokingAllowed()
    if not authorized then
        return true
    end
    local resource = GetInvokingResource()
    -- No invoking resource means the call came from cis_libs' own code (a net event, or
    if not resource or resource == GetCurrentResourceName() then
        return true
    end
    return authorized[resource] == true
end

function CisInvokingAllowed()
    return invokingAllowed()
end

-- A fixed window, not a sliding one, and not a token bucket.
local RATE_BUCKET_CAP = 256

local function rateOk(src, name, windowMs, maxHits)
    windowMs = windowMs or 1000
    maxHits = maxHits or 8
    local now = GetGameTimer()
    local perSrc = rates[src]
    if not perSrc then
        perSrc = {}
        rates[src] = perSrc
    end
    local bucket = perSrc[name]
    if not bucket or now - bucket.started >= windowMs then
        -- The cap is checked only when a NEW name appears.
        if not bucket and (rateCounts[src] or 0) >= RATE_BUCKET_CAP then
            -- Refuse rather than allocate.
            CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
            return false
        end
        perSrc[name] = { started = now, hits = 1 }
        rateCounts[src] = (rateCounts[src] or 0) + 1
        return true
    end
    bucket.hits = bucket.hits + 1
    local allowed = bucket.hits <= maxHits
    if not allowed then
        -- Counted HERE, at the single place a request is actually turned away, rather
        CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
    end
    return allowed
end

function CisRateOk(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end

--- How many rate buckets a source is currently holding.
--- @param src number
--- @return number
function CisRateBucketCount(src)
    return rateCounts[src] or 0
end

-- ONCE PER (src, event) PER WINDOW, carrying the number dropped.
local RATE_WARN_LIMIT = 100
local rateWarned = {}

local function warnRateLimited(src, name)
    local key = tostring(src) .. '\29' .. tostring(name)
    local state = rateWarned[key]
    local now = GetGameTimer()

    if state then
        if now - state.windowStarted >= 1000 then
            -- The window just rolled. ONE line, carrying the total it cost.
            CisLog('warn', ('rate limited %s from %s: %d events dropped in one second')
                :format(tostring(name), tostring(src), state.count), 'cheating')
            state.windowStarted = now
            state.count = 1
            state.escalated = false
            return
        end
        state.count = state.count + 1
        if state.count > RATE_WARN_LIMIT and not state.escalated then
            state.escalated = true
            CisSecurityReport(src, ('rate limited %s: %d events dropped in one second')
                :format(tostring(name), state.count))
        end
        return
    end

    rateWarned[key] = { count = 1, windowStarted = now, escalated = false }
end

-- A player who drops takes their rate buckets, their bucket COUNT and their warning
AddEventHandler('playerDropped', function()
    rates[source] = nil
    rateCounts[source] = nil
    local prefix = tostring(source) .. '\29'
    for k in pairs(rateWarned) do
        if k:sub(1, #prefix) == prefix then
            rateWarned[k] = nil
        end
    end
end)

-- Every net event a client can reach goes through here.
local function isCallableRef(v)
    if type(v) == 'function' then
        return true
    end
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') ~= nil
end

-- `fn` may be a function OR a `'resource:export'` reference string.
local netBindings = {}

-- 7.11. opts.schema is a map of field -> { type, min, max, maxLen, optional }.
local function checkNetSchema(schema, payload)
    if type(schema) ~= 'table' then
        return false, 'schema must be a table'
    end
    if type(payload) ~= 'table' then
        return false, ('payload must be a table, got %s'):format(type(payload))
    end
    for field, rule in pairs(schema) do
        if type(field) == 'string' and type(rule) == 'table' then
            local v = payload[field]
            if v == nil then
                if not rule.optional then
                    return false, ('missing %s'):format(field)
                end
            else
                local want = rule.type
                if type(want) == 'string' and type(v) ~= want then
                    return false, ('%s expected %s, got %s'):format(field, want, type(v))
                end
                if type(v) == 'number' then
                    if v ~= v then
                        return false, ('%s is NaN'):format(field)
                    end
                    if type(rule.min) == 'number' and v < rule.min then
                        return false, ('%s below min %s'):format(field, tostring(rule.min))
                    end
                    if type(rule.max) == 'number' and v > rule.max then
                        return false, ('%s above max %s'):format(field, tostring(rule.max))
                    end
                elseif type(v) == 'string' then
                    if type(rule.maxLen) == 'number' and #v > rule.maxLen then
                        return false, ('%s longer than %s'):format(field, tostring(rule.maxLen))
                    end
                elseif type(v) == 'table' then
                    if type(rule.maxLen) == 'number' and #v > rule.maxLen then
                        return false, ('%s has more than %s entries'):format(field, tostring(rule.maxLen))
                    end
                end
            end
        end
    end
    return true
end

function CisNetOn(name, fn, opts)
    opts = opts or {}

    local resource, exportName, self, handler
    if type(fn) == 'string' then
        resource, exportName = fn:match('^([^:]+):(.+)$')
        if resource and exportName then
            -- pcall BECAUSE LOOKING UP A MISSING EXPORT RAISES.
            local ok, fetched = pcall(function()
                local res = exports[resource]
                return res and res[exportName] or nil
            end)
            if ok then
                self = exports[resource]
                handler = fetched
            end
        end
        if not isCallableRef(handler) then
            handler = nil
        end
    elseif type(fn) == 'function' then
        resource = GetInvokingResource() or 'cis_libs'
        handler = fn
    end

    if not handler then
        -- The message has to name the REFERENCE, not just the type.
        if type(fn) == 'string' and resource and exportName then
            Logging.Error(('Cis.net.on("%s") registered nothing: resource %q does '
                .. 'not export %q. Check the name, and that the resource is started.')
                :format(tostring(name), tostring(resource), tostring(exportName)))
        else
            Logging.Error(('Cis.net.on("%s") registered nothing: the handler must be a function '
                .. '(cis_libs only) or a "resource:export" reference, not %s')
                :format(tostring(name), type(fn)))
        end
        return false
    end

    local binding = netBindings[name]
    if binding then
        -- Same owner, re-registering: exactly what a `onResourceStart` handler after a
        if binding.owner == resource then
            binding.self = self
            binding.handler = handler
            binding.opts = opts
            binding.resource = resource
            binding.exportName = exportName
            return true
        end
        Logging.Warn(('cis_libs: net event %q is already bound by %s; %s was refused')
            :format(tostring(name), tostring(binding.owner), tostring(resource)))
        return false
    end

    netBindings[name] = {
        owner = resource, resource = resource, exportName = exportName,
        self = self, handler = handler, opts = opts,
    }

    RegisterNetEvent(name, function(...)
        local src = source
        if type(src) ~= 'number' or src <= 0 then
            return
        end
        local live = netBindings[name]
        if not live then
            return
        end
        -- Re-resolved per call: a restarted resource exports new closures, and a
        local target = live.handler
        local exportsTable = live.self
        if live.exportName then
            exportsTable = exports[live.resource]
            target = exportsTable and exportsTable[live.exportName]
            if not isCallableRef(target) then
                -- The owning resource is gone, or has not finished restarting.
                return
            end
        end
        if not isCallableRef(target) then
            return
        end
        if live.opts.schema ~= nil then
            local payload = ...
            local schemaOk, schemaWhy = checkNetSchema(live.opts.schema, payload)
            if not schemaOk then
                CisDiagnostics.Inc(CisDiagnostics.NAMES.NET_SCHEMA_REFUSED)
                CisSecurityReport(src, ('bad net payload %s: %s'):format(tostring(name), tostring(schemaWhy)))
                return
            end
        end
        if not rateOk(src, name, live.opts.windowMs, live.opts.maxHits) then
            -- ONE WARNING PER (src, name) PER WINDOW, with the number dropped.
            warnRateLimited(src, name)
            return
        end
        local ok, err
        if exportsTable then
            ok, err = pcall(target, exportsTable, src, ...)
        else
            ok, err = pcall(target, src, ...)
        end
        if not ok then
            Logging.AutoLogError(err, name)
        end
    end)
    -- true once the event is actually bound.
    return true
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
    -- A custom drop handler is a FUNCTION, and a function cannot be sent across the
    local ok = CisRegistry.call('security', 'drop', src, reason)
    if ok then
        return true
    end
    if Security and Security.DropPlayer then
        DropPlayer(src, DEFAULT_DROP_MESSAGE)
        return true
    end
    return false
end

-- THE RESULT IS RETURNED, AND `opts` IS PASSED THROUGH.
exports('SecureNetOn', function(name, fn, opts)
    return CisNetOn(name, fn, opts)
end)

-- Exposed so a companion resource can ask "would a mutation from me be allowed?" before
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

-- A resource that stops takes its net bindings with it ().
AddEventHandler('onResourceStop', function(resource)
    for name, binding in pairs(netBindings) do
        if binding.owner == resource then
            netBindings[name] = nil
        end
    end
end)

-- Net handlers are registered per resource and released on its stop, so the count is
CisDiagnostics.Register('server', 'netHandlers', function()
    local out, perResource = 0, {}
    for _, binding in pairs(netBindings) do
        out = out + 1
        local owner = binding.owner or '<none>'
        perResource[owner] = (perResource[owner] or 0) + 1
    end
    return { total = out, byOwner = perResource }
end)

CisDiagnostics.Register('server', 'rateBuckets', function()
    local total = 0
    for _ in pairs(rateCounts) do total = total + 1 end
    return { srcs = total, cap = RATE_BUCKET_CAP }
end)
