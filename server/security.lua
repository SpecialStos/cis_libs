-- Net-event gate, rate limiter, and the door/sync allow-list.

local rates = {}
-- How many buckets each src is holding, kept as a COUNTER beside the map.
local rateCounts = {}
local authorized

-- Postures for the "AuthorizedResources is empty" case.
local posture

-- SERVER CONVARS ARE AUTHORITATIVE. A convar is set by the operator in server.cfg,
-- before any resource runs; `SetConfig` is called by whichever resource gets there
-- first. So what the operator said with a convar, no resource can unsay. An unset
-- or blank convar is "not said", and the Security table decides.
local function convar(name)
    if type(GetConvar) ~= 'function' then
        return nil
    end
    local ok, value = pcall(GetConvar, name, '')
    if not ok or type(value) ~= 'string' then
        return nil
    end
    value = value:match('^%s*(.-)%s*$')
    if value == '' then
        return nil
    end
    return value
end

local function convarBool(name)
    local raw = convar(name)
    if raw == nil then
        return nil
    end
    raw = raw:lower()
    return raw == 'true' or raw == '1' or raw == 'yes' or raw == 'on'
end

-- `set cis_authorized_resources "cis_core,cis_keys"`. Commas or spaces separate.
local function convarList(name)
    local raw = convar(name)
    if raw == nil then
        return nil
    end
    local list = {}
    for piece in raw:gmatch('[^,%s]+') do
        list[#list + 1] = piece
    end
    return list
end

-- Whether the operator pinned the posture with either security convar. When they
-- did, Security.AuthorizedResources and Security.AllowAnyResource are IGNORED
-- whole, not merged: a pin that a later SetConfig could widen is not a pin.
local function postureFromConvars()
    return convar('cis_authorized_resources') ~= nil or convar('cis_allow_any_resource') ~= nil
end

-- An empty table is treated as "not configured", the same as nil.
local function configuredList()
    local list
    if postureFromConvars() then
        list = convarList('cis_authorized_resources')
    else
        list = Security and Security.AuthorizedResources
    end
    if type(list) ~= 'table' or #list == 0 then
        return nil
    end
    return list
end

-- THE ESCAPE HATCH, AND IT IS OPT-IN AND VALIDATED.
local function allowAnyResource()
    if postureFromConvars() then
        return convarBool('cis_allow_any_resource') == true
    end
    return Security and Security.AllowAnyResource == true
end


local function reportRestrictive(reason)
    print('[cis_libs] SECURITY: door and sync mutations are REFUSED for every resource except cis_libs.')
    print(('  %s'):format(reason))
    print('  Security.AuthorizedResources is empty, and an empty list is always restrictive:')
    print('  an empty list used to mean "any server-side resource may add, break and rewrite doors".')
    print('  Name the resources that mutate doors in server.cfg (this wins over SetConfig):')
    print('      set cis_authorized_resources "cis_storeRobberies,cis_housing"')
    print('  or, with no convar set, from the resource that supplies the configuration:')
    print('      Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" }')
    print('  A resource can ask first: exports["cis_libs"]:InvokingAllowed().')
    print('  To restore the old permissive behaviour for every resource instead, set')
    print('      set cis_allow_any_resource true   (or Security.AllowAnyResource = true)')
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
        print('[cis_libs] SECURITY: AllowAnyResource is TRUE -- every server-side')
        print('  resource may mutate doors and sync records. This is the 1.0.0 escape hatch')
        print('  and it is deliberately loud. To turn it off:')
        print('      set cis_allow_any_resource false   (or Security.AllowAnyResource = false)')
        print('  To allow only the resources you name instead:')
        print('      set cis_authorized_resources "cis_storeRobberies,cis_housing"')
        print('      (or Security.AuthorizedResources = { "cis_storeRobberies", "cis_housing" })')
    end
end

-- The callback limits: convar first, then Config.CallbackLimits, then the built-in
-- default, clamped whichever answered. CACHED, because the reader is the
-- `cis_libs:cb` hot path: re-read at most once a second (a console `set` lands
-- within that) and at once on SetConfig, which calls CisSecurityRebuild.
local LIMITS = {
    perName = { convar = 'cis_cb_rate_per_name', key = 'PerName', default = 20, min = 1, max = 10000 },
    perPlayer = { convar = 'cis_cb_rate_per_player', key = 'PerPlayer', default = 60, min = 1, max = 100000 },
    windowMs = { convar = 'cis_cb_window_ms', key = 'WindowMs', default = 1000, min = 100, max = 60000 },
    maxInFlight = { convar = 'cis_cb_max_inflight', key = 'MaxInFlight', default = 8, min = 1, max = 1000 },
    maxStringLen = { convar = 'cis_cb_max_string_len', key = 'MaxStringLen', default = 4096, min = 16, max = 1048576 },
}
local limitsCache, limitsReadAt = nil, 0

local function readLimits()
    local out = {}
    local configured = Config and type(Config.CallbackLimits) == 'table' and Config.CallbackLimits or {}
    for name, spec in pairs(LIMITS) do
        local value = tonumber(convar(spec.convar)) or tonumber(configured[spec.key]) or spec.default
        if value ~= value then
            value = spec.default
        end
        out[name] = math.max(spec.min, math.min(spec.max, math.floor(value)))
    end
    return out
end

--- The effective callback limits.
--- @return table { perName, perPlayer, windowMs, maxInFlight, maxStringLen }
function CisCallbackLimits()
    local now = GetGameTimer()
    if not limitsCache or now - limitsReadAt >= 1000 or now < limitsReadAt then
        limitsCache = readLimits()
        limitsReadAt = now
    end
    return limitsCache
end

-- Decides the allow-list. Two cases, and both are DEFINITE:
local function rebuildAuthorized()
    authorized = nil
    limitsCache = nil
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
        applyPosture('permissive', 'AllowAnyResource is set')
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

--- Whether the posture is pinned by server convars, so SetConfig can say so.
--- @return boolean
function CisSecurityPinned()
    return postureFromConvars()
end

--- The posture in force: 'configured', 'permissive' or 'restrictive'.
--- @return string
function CisSecurityPosture()
    return posture
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
    if not bucket then
        -- The cap is checked only when a NEW name appears, and only a new name is
        -- COUNTED: the count is how many buckets this src holds, not how many
        -- windows have rolled, or a long session runs into the cap by playing.
        if (rateCounts[src] or 0) >= RATE_BUCKET_CAP then
            -- Refuse rather than allocate.
            CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
            return false
        end
        perSrc[name] = { started = now, hits = 1 }
        rateCounts[src] = (rateCounts[src] or 0) + 1
        return true
    end
    if now - bucket.started >= windowMs then
        -- The window rolled: the SAME table, refilled. No allocation, no count.
        bucket.started = now
        bucket.hits = 1
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

-- A FLOOD IS REPORTED BY ITS SHAPE, not by its seconds. One line when it starts
-- (emitted as its first window rolls, carrying that window's total), nothing for
-- the windows after it, one escalation when it has lasted RATE_ESCALATE_WINDOWS
-- windows in a row or blew past RATE_WARN_LIMIT inside one, and one closing line
-- carrying the whole total when it is over. A client firing at 60Hz for an hour
-- used to be 3600 console lines and 3600 Discord posts.
local RATE_WARN_LIMIT = 100
local RATE_ESCALATE_WINDOWS = 5
local RATE_WINDOW_MS = 1000
-- src -> name -> state. Keyed by src first so a drop is one assignment.
local rateWarned = {}

local function warnRateLimited(src, name)
    local perSrc = rateWarned[src]
    if not perSrc then
        perSrc = {}
        rateWarned[src] = perSrc
    end
    local state = perSrc[name]
    local now = GetGameTimer()

    if not state then
        perSrc[name] = {
            count = 1, windowStarted = now, windows = 1, total = 1,
            escalated = false, announced = false,
        }
        return
    end

    local elapsed = now - state.windowStarted
    if elapsed >= RATE_WINDOW_MS then
        -- The window rolled. Was the gap one window (the flood went on) or more
        -- (it stopped, and this is a new one)?
        local continued = elapsed < 2 * RATE_WINDOW_MS
        if not state.announced then
            -- ONE line, carrying the total it cost.
            CisLog('warn', ('rate limited %s from %s: %d events dropped in one second')
                :format(tostring(name), tostring(src), state.count), 'cheating')
            state.announced = true
        end
        if not continued then
            if state.windows > 1 then
                CisLog('warn', ('rate limit flood of %s from %s ended: %d events dropped over %d windows')
                    :format(tostring(name), tostring(src), state.total, state.windows), 'cheating')
            end
            state.windows = 0
            state.total = 0
            state.escalated = false
            state.announced = false
        end
        state.windowStarted = now
        state.count = 1
        state.windows = state.windows + 1
        state.total = state.total + 1
        if state.windows >= RATE_ESCALATE_WINDOWS and not state.escalated then
            state.escalated = true
            CisSecurityReport(src, ('rate limited %s for %d windows in a row: %d events dropped')
                :format(tostring(name), state.windows, state.total))
        end
        return
    end
    state.count = state.count + 1
    state.total = state.total + 1
    if state.count > RATE_WARN_LIMIT and not state.escalated then
        state.escalated = true
        CisSecurityReport(src, ('rate limited %s: %d events dropped in one second')
            :format(tostring(name), state.count))
    end
end

-- A player who drops takes their rate buckets, their bucket COUNT and their warning
AddEventHandler('playerDropped', function()
    rates[source] = nil
    rateCounts[source] = nil
    rateWarned[source] = nil
end)

-- `fn` may be a function OR a `'resource:export'` reference string.
local netBindings = {}
-- Every name RegisterNetEvent has been called for. FiveM cannot unbind a net
-- handler, so a name is registered ONCE for the life of cis_libs and the one
-- handler reads the live binding. A consumer that stops and starts again gets its
-- binding back, not a second handler beside the first -- which ran every client
-- event once per restart, and a payout handler paid out N+1 times.
local netRegistered = {}

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

-- The same check, for server/callback.lua's `schema` option: one rule set, one
-- implementation, so a net event and a callback cannot disagree about a payload.
function CisCheckNetSchema(schema, payload)
    return checkNetSchema(schema, payload)
end

local function dispatch(name, ...)
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
        if not CisCallable(target) then
            -- The owning resource is gone, or has not finished restarting.
            return
        end
    end
    if not CisCallable(target) then
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
        -- ONE WARNING PER (src, name) PER FLOOD, with the number dropped.
        warnRateLimited(src, name)
        return
    end
    -- xpcall, not pcall: the trap runs BEFORE the stack unwinds, so the logged
    -- file, line and trace are the handler's, not this dispatcher's.
    local trap = Logging.Trap or debug.traceback
    local ok, err
    if exportsTable then
        ok, err = xpcall(target, trap, exportsTable, src, ...)
    else
        ok, err = xpcall(target, trap, src, ...)
    end
    if not ok then
        Logging.AutoLogError(err, name)
    end
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
        if not CisCallable(handler) then
            handler = nil
        end
    elseif CisCallable(fn) then
        -- A function, or a function ANOTHER resource passed through the export,
        -- which arrives as a callable reference table. Owned by the invoker either
        -- way, and released with it on onResourceStop below.
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
                .. 'or a "resource:export" reference, not %s')
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

    if not netRegistered[name] then
        netRegistered[name] = true
        RegisterNetEvent(name, function(...)
            return dispatch(name, ...)
        end)
    end
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
    local registered = 0
    for _ in pairs(netRegistered) do registered = registered + 1 end
    return { total = out, byOwner = perResource, registered = registered }
end)

CisDiagnostics.Register('server', 'rateBuckets', function()
    local total = 0
    for _ in pairs(rateCounts) do total = total + 1 end
    return { srcs = total, cap = RATE_BUCKET_CAP }
end)
