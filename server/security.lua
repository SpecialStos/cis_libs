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
    print('  An empty list is always restrictive. It used to mean')
    print('  "any server-side resource may add, break and rewrite doors".')
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

--- The allow-list as a client may see it, for its capability gate: 'any' when
--- every resource is allowed, else the sorted digest of each allowed name.
--- @return string|string[]
function CisSecurityDigests()
    if not authorized then
        return 'any'
    end
    local out = {}
    for name in pairs(authorized) do
        out[#out + 1] = CisConfigUtil.digest(name)
    end
    table.sort(out)
    return out
end

-- A fixed window, not a sliding one, and not a token bucket.
local RATE_BUCKET_CAP = 256

-- Buckets whose window has passed hold nothing a fresh bucket would not, so
-- they are dropped to make room. Answers how many were dropped.
local function evictExpired(src, perSrc, now)
    local dropped = 0
    for key, bucket in pairs(perSrc) do
        if now - bucket.started >= bucket.windowMs then
            perSrc[key] = nil
            dropped = dropped + 1
        end
    end
    rateCounts[src] = (rateCounts[src] or 0) - dropped
    return dropped
end

-- KEYS THAT ARE NOT CONNECTED PLAYERS are never freed by playerDropped: a
-- consumer calling RateOk('license:...') or with a stale id held those buckets
-- for the life of cis_libs. They are tracked on their own, idle ones (every
-- window passed) are swept at most once per NONPLAYER_SWEEP_MS, and a new one
-- past NONPLAYER_SRC_CAP live keys is refused rather than allocated. A
-- connected player is never counted here, so a full table never refuses one.
local NONPLAYER_SRC_CAP = 1024
local NONPLAYER_SWEEP_MS = 60000
local NONPLAYER_FULL_SWEEP_MS = 1000
local nonPlayer, nonPlayerCount = {}, 0
local lastNonPlayerSweep = nil

local function isFinite(n)
    return n == n and n ~= math.huge and n ~= -math.huge
end

local function sweepNonPlayers(now)
    lastNonPlayerSweep = now
    for key in pairs(nonPlayer) do
        local live = false
        for _, bucket in pairs(rates[key] or {}) do
            if now - bucket.started < bucket.windowMs then
                live = true
                break
            end
        end
        if not live then
            nonPlayer[key] = nil
            nonPlayerCount = nonPlayerCount - 1
            rates[key] = nil
            rateCounts[key] = nil
        end
    end
end

-- A NEW key's bucket set: a connected player's, or a non-player's under the
-- bound above. Answers nil and a reason when the non-player keys are full.
local function bucketsFor(src, now)
    if type(src) == 'number' and src > 0 and GetPlayerName(src) ~= nil then
        local perSrc = {}
        rates[src] = perSrc
        return perSrc
    end
    local due = lastNonPlayerSweep == nil or now < lastNonPlayerSweep
        or now - lastNonPlayerSweep >= NONPLAYER_SWEEP_MS
        or (nonPlayerCount >= NONPLAYER_SRC_CAP and now - lastNonPlayerSweep >= NONPLAYER_FULL_SWEEP_MS)
    if due then
        sweepNonPlayers(now)
    end
    if nonPlayerCount >= NONPLAYER_SRC_CAP then
        return nil, 'cap'
    end
    local perSrc = {}
    rates[src] = perSrc
    nonPlayer[src] = true
    nonPlayerCount = nonPlayerCount + 1
    return perSrc
end

-- Answers allowed, and 'cap' when a NEW name was refused only because this src
-- holds RATE_BUCKET_CAP live buckets: that is the limiter's own bound, not the
-- player flooding the event, and is never escalated as one. Bad input (a nil,
-- NaN or empty src, a nil name, a window or limit that is not a positive finite
-- number) is `false, reason` -- it used to raise inside cis_libs, or build a
-- bucket that never rolled.
local function rateOk(src, name, windowMs, maxHits)
    windowMs = windowMs == nil and 1000 or windowMs
    maxHits = maxHits == nil and 8 or maxHits
    -- ONE KEY PER PLAYER. GetPlayers() hands out ids as strings, and a string
    -- src got buckets that playerDropped (which clears the number) never freed.
    src = tonumber(src) or src
    if type(src) == 'number' then
        if not isFinite(src) then
            return false, 'src must be a finite number or a non-empty string'
        end
    elseif type(src) ~= 'string' or src == '' then
        return false, 'src must be a finite number or a non-empty string'
    end
    if (type(name) ~= 'string' or name == '') and not (type(name) == 'number' and isFinite(name)) then
        return false, 'name must be a non-empty string'
    end
    if type(windowMs) ~= 'number' or not isFinite(windowMs) or windowMs <= 0 then
        return false, 'windowMs must be a positive finite number'
    end
    if type(maxHits) ~= 'number' or not isFinite(maxHits) or maxHits < 1 then
        return false, 'maxHits must be a number of at least 1'
    end
    local now = GetGameTimer()
    local perSrc = rates[src]
    if not perSrc then
        local why
        perSrc, why = bucketsFor(src, now)
        if not perSrc then
            CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
            return false, why
        end
    end
    local bucket = perSrc[name]
    if not bucket then
        -- The cap is checked only when a NEW name appears, and only a new name is
        -- COUNTED: the count is how many buckets this src holds, not how many
        -- windows have rolled, or a long session runs into the cap by playing.
        -- Buckets never expired, so a consumer using dynamic names filled the cap
        -- and every new name was refused for the session; expired ones go first.
        if (rateCounts[src] or 0) >= RATE_BUCKET_CAP then
            evictExpired(src, perSrc, now)
        end
        if (rateCounts[src] or 0) >= RATE_BUCKET_CAP then
            -- Refuse rather than allocate.
            CisDiagnostics.Inc(CisDiagnostics.NAMES.RATE_LIMITED)
            return false, 'cap'
        end
        perSrc[name] = { started = now, hits = 1, windowMs = windowMs }
        rateCounts[src] = (rateCounts[src] or 0) + 1
        return true
    end
    bucket.windowMs = windowMs
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
        return false, 'limited'
    end
    return true
end

function CisRateOk(src, name, windowMs, maxHits)
    return rateOk(src, name, windowMs, maxHits)
end

--- How many rate buckets a source is currently holding.
--- @param src number
--- @return number
function CisRateBucketCount(src)
    return rateCounts[tonumber(src) or src] or 0
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

-- src -> name -> GetGameTimer() of the last bad payload of that event. A bad
-- payload is reported when there is no entry, or when the last one is at least
-- a quiet interval old; every bad payload refreshes it, so a flood that keeps
-- going stays one report and a repeat after a pause is a new strike.
local schemaReported = {}
local BAD_PAYLOAD_QUIET_MS = 5000

-- A player who drops takes their rate buckets, their bucket COUNT and their warning
AddEventHandler('playerDropped', function()
    rates[source] = nil
    rateCounts[source] = nil
    if nonPlayer[source] then
        nonPlayer[source] = nil
        nonPlayerCount = nonPlayerCount - 1
    end
    rateWarned[source] = nil
    schemaReported[source] = nil
end)

-- `fn` may be a function OR a `'resource:export'` reference string.
local netBindings = {}
-- Every name RegisterNetEvent has been called for. FiveM cannot unbind a net
-- handler, so a name is registered ONCE for the life of cis_libs and the one
-- handler reads the live binding. A consumer that stops and starts again gets its
-- binding back, not a second handler beside the first -- which ran every client
-- event once per restart, and a payout handler paid out N+1 times.
local netRegistered = {}

-- The largest whole number a double holds exactly. Past it, 2^53 + 1 reads back
-- as 2^53, so an "integer" there is not the integer the client meant.
local MAX_SAFE_INTEGER = 2 ^ 53

-- 7.11. opts.schema is a map of field -> { type, min, max, maxLen, optional, finite }.
-- `type` is a Lua type name, plus 'integer': a whole, finite number within
-- +-2^53. A number is refused when it is NaN, and when it is infinite unless
-- the rule says `finite = false`.
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
                local integer = want == 'integer'
                if integer then
                    want = 'number'
                end
                if type(want) == 'string' and type(v) ~= want then
                    return false, ('%s expected %s, got %s'):format(field, rule.type, type(v))
                end
                if type(v) == 'number' then
                    if v ~= v then
                        return false, ('%s is NaN'):format(field)
                    end
                    if (v == math.huge or v == -math.huge) and (integer or rule.finite ~= false) then
                        return false, ('%s is not finite'):format(field)
                    end
                    if integer and (v > MAX_SAFE_INTEGER or v < -MAX_SAFE_INTEGER) then
                        return false, ('%s expected integer within +-2^53, got %s'):format(field, tostring(v))
                    end
                    if integer and math.floor(v) ~= v then
                        return false, ('%s expected integer, got %s'):format(field, tostring(v))
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

-- The types a schema rule may name: what type() answers for a decoded client
-- argument (LuaGLM vectors included), plus 'integer'.
local SCHEMA_TYPES = {
    string = true, number = true, integer = true, boolean = true, table = true,
    vector2 = true, vector3 = true, vector4 = true, quat = true,
}

-- A SCHEMA IS CHECKED WHEN IT IS REGISTERED. The checker skips what it cannot
-- read, so a string schema, a rule that is not a table or a typo in a type
-- name was a binding that refused -- and reported, and on most servers kicked
-- -- every player who sent the event. Answers true, or false and the first
-- thing wrong with it.
local function validateNetSchema(schema)
    if type(schema) ~= 'table' then
        return false, ('schema must be a map of field -> { type, min, max, maxLen, optional }, got %s')
            :format(type(schema))
    end
    for field, rule in pairs(schema) do
        if type(field) ~= 'string' then
            return false, ('schema field names must be strings, got %s'):format(type(field))
        end
        if type(rule) ~= 'table' then
            return false, ('schema.%s must be a rule table, got %s'):format(field, type(rule))
        end
        if rule.type ~= nil and not SCHEMA_TYPES[rule.type] then
            return false, ('schema.%s.type %s is not a known type'):format(field, tostring(rule.type))
        end
        for _, key in ipairs({ 'min', 'max', 'maxLen' }) do
            local v = rule[key]
            if v ~= nil and (type(v) ~= 'number' or v ~= v) then
                return false, ('schema.%s.%s must be a number, got %s'):format(field, key, tostring(v))
            end
        end
        for _, key in ipairs({ 'optional', 'finite' }) do
            if rule[key] ~= nil and type(rule[key]) ~= 'boolean' then
                return false, ('schema.%s.%s must be true or false, got %s'):format(field, key, type(rule[key]))
            end
        end
    end
    return true
end

--- The same registration check for server/callback.lua's `schema` option.
function CisValidateNetSchema(schema)
    return validateNetSchema(schema)
end

-- How much of a client's payload is worth walking before it is refused. The
-- same bounds for a net event and a callback; a net event may raise its own.
local MAX_PAYLOAD_ARGS = 32
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
    if depth > budget.maxDepth then
        return false
    end
    local seen = 0
    for k, v in pairs(value) do
        seen = seen + 1
        if seen > budget.maxEntries then
            return false
        end
        budget.n = budget.n + 1
        if budget.n > budget.maxEntries then
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

--- Whether a packed argument list fits: at most maxArgs arguments, every string
--- (key or value) at most maxLen bytes, tables at most maxDepth deep and at most
--- maxEntries entries counted across the whole payload. maxArgs, maxEntries and
--- maxDepth default to 32, 256 and 8.
--- @return boolean
function CisPayloadWithinLimits(packed, maxArgs, maxLen, maxEntries, maxDepth)
    if packed.n > (maxArgs or MAX_PAYLOAD_ARGS) then
        return false
    end
    local budget = { n = 0, maxEntries = maxEntries or MAX_TABLE_KEYS, maxDepth = maxDepth or MAX_NESTING }
    for i = 1, packed.n do
        if not withinLimits(packed[i], budget, 1, maxLen) then
            return false
        end
    end
    return true
end

-- The per-handler payload limits a net binding may carry. Each is a positive
-- number; anything else is a refusal that names itself.
local NET_LIMIT_OPTIONS = { 'maxArgs', 'maxStringLen', 'maxEntries', 'maxDepth' }

local function readNetLimits(name, opts)
    for i = 1, #NET_LIMIT_OPTIONS do
        local key = NET_LIMIT_OPTIONS[i]
        local value = opts[key]
        if value ~= nil and (type(value) ~= 'number' or value ~= value or value < 1) then
            return false, ('Cis.net.on("%s"): opts.%s must be a positive number, got %s')
                :format(tostring(name), key, tostring(value))
        end
    end
    -- The limiter's own two. A NaN window never rolled, and maxHits 0 let the
    -- first hit of every window through.
    for _, key in ipairs({ 'windowMs', 'maxHits' }) do
        local value = opts[key]
        if value ~= nil and (type(value) ~= 'number' or value ~= value or value == math.huge or value < 1) then
            return false, ('Cis.net.on("%s"): opts.%s must be a finite number of at least 1, got %s')
                :format(tostring(name), key, tostring(value))
        end
    end
    if opts.schema ~= nil then
        local schemaOk, schemaWhy = validateNetSchema(opts.schema)
        if not schemaOk then
            return false, ('Cis.net.on("%s"): opts.%s'):format(tostring(name), schemaWhy)
        end
    end
    return true
end

-- ONE REPORT per player and event per run of bad payloads; the rest are counted
-- only. A run ends after a quiet interval, so a repeat after a pause is reported
-- as a new strike, and a provider that bans after N strikes sees strike two.
-- `label` names the kind in the report ('net' or 'callback') and keys the
-- ledger, so a net event and a callback of the same name are separate runs.
-- Both kinds key on a REGISTERED name, so the ledger is bounded by what was bound.
local function reportBadPayload(src, name, why, windowMs, label)
    label = label or 'net'
    CisDiagnostics.Inc(CisDiagnostics.NAMES.NET_SCHEMA_REFUSED)
    local perSrc = schemaReported[src]
    if not perSrc then
        perSrc = {}
        schemaReported[src] = perSrc
    end
    local now = GetGameTimer()
    local ledgerKey = label == 'net' and name or (label .. ' ' .. tostring(name))
    local last = perSrc[ledgerKey]
    perSrc[ledgerKey] = now
    local quiet = math.max(BAD_PAYLOAD_QUIET_MS, 2 * (windowMs or 1000))
    if last == nil or now - last >= quiet or now < last then
        CisSecurityReport(src, ('bad %s payload %s: %s'):format(label, tostring(name), tostring(why)))
    end
end

--- The same one-report-per-run latch, for server/callback.lua's schema option.
function CisReportBadPayload(src, name, why, windowMs, label)
    return reportBadPayload(src, name, why, windowMs, label)
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
        -- UNDER pcall: indexing a stopped resource's exports, or a name it does
        -- not export, RAISES in FiveM rather than answering nil.
        local found, et, fn = pcall(function()
            local t = exports[live.resource]
            return t, t and t[live.exportName]
        end)
        exportsTable, target = et, fn
        if not found or not CisCallable(target) then
            -- The owning resource is gone, or has not finished restarting.
            return
        end
    end
    if not CisCallable(target) then
        return
    end
    -- THE RATE LIMIT FIRST. Checked after the schema, every malformed event in a
    -- flood was a security report: a console line and a provider call each.
    local allowed, capped = rateOk(src, name, live.opts.windowMs, live.opts.maxHits)
    if not allowed then
        -- ONE WARNING PER (src, name) PER FLOOD, with the number dropped. A
        -- refusal at the bucket cap is not this event flooding, and kicking a
        -- player for the limiter's own bound was the old outcome.
        if capped ~= 'cap' then
            warnRateLimited(src, name)
        end
        return
    end
    -- THEN THE SIZE, before the schema and the handler walk any of it. A net event
    -- used to get only the first argument's schema: 200 arguments, a 4 MB string
    -- or a table nested a thousand deep all reached the handler.
    local opts = live.opts
    local packed = table.pack(...)
    if not CisPayloadWithinLimits(packed, opts.maxArgs,
            opts.maxStringLen or CisCallbackLimits().maxStringLen, opts.maxEntries, opts.maxDepth) then
        reportBadPayload(src, name, 'payload too large', opts.windowMs)
        return
    end
    if live.opts.schema ~= nil then
        local payload = ...
        local schemaOk, schemaWhy = checkNetSchema(live.opts.schema, payload)
        if not schemaOk then
            reportBadPayload(src, name, schemaWhy, opts.windowMs)
            return
        end
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

-- Every refusal is `false, reason`, logged once here.
local function refuseNet(level, why)
    if level == 'warn' then
        Logging.Warn(why)
    else
        Logging.Error(why)
    end
    return false, why
end

function CisNetOn(name, fn, opts)
    if type(name) ~= 'string' or name == '' then
        return refuseNet('error', ('Cis.net.on: the event name must be a non-empty string, got %s'):format(type(name)))
    end
    opts = opts or {}
    if type(opts) ~= 'table' then
        return refuseNet('error', ('Cis.net.on("%s"): opts must be a table, got %s'):format(name, type(opts)))
    end
    local limitsOk, limitsWhy = readNetLimits(name, opts)
    if not limitsOk then
        return refuseNet('error', limitsWhy)
    end

    -- THE OWNER IS THE CALLER, never the reference string. Parsed from
    -- 'bank:anyExport', any resource could pass the owner check below and replace
    -- bank's binding, schema and rate limit with its own.
    local owner = GetInvokingResource() or 'cis_libs'
    local resource, exportName, self, handler
    if type(fn) == 'string' then
        resource, exportName = fn:match('^([^:]+):(.+)$')
        if resource and resource ~= owner and owner ~= GetCurrentResourceName() then
            return refuseNet('warn', ('cis_libs: %s tried to bind net event %q to %s, which is not its own export; refused')
                :format(tostring(owner), tostring(name), tostring(fn)))
        end
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
        resource = owner
        handler = fn
    end

    if not handler then
        -- The message has to name the REFERENCE, not just the type.
        if type(fn) == 'string' and resource and exportName then
            return refuseNet('error', ('Cis.net.on("%s") registered nothing: resource %q does '
                .. 'not export %q. Check the name, and that the resource is started.')
                :format(tostring(name), tostring(resource), tostring(exportName)))
        end
        return refuseNet('error', ('Cis.net.on("%s") registered nothing: the handler must be a function '
            .. 'or a "resource:export" reference, not %s')
            :format(tostring(name), type(fn)))
    end

    local binding = netBindings[name]
    if binding then
        -- Same owner, re-registering: exactly what a `onResourceStart` handler after a
        if binding.owner == owner then
            binding.self = self
            binding.handler = handler
            binding.opts = opts
            binding.resource = resource
            binding.exportName = exportName
            return true
        end
        return refuseNet('warn', ('cis_libs: net event %q is already bound by %s; %s was refused')
            :format(tostring(name), tostring(binding.owner), tostring(owner)))
    end

    netBindings[name] = {
        owner = owner, resource = resource, exportName = exportName,
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

-- A consumer's buckets are its own. The export used to share keys with the net
-- events cis_libs limits itself, so RateOk(src, 'cis_libs:x') spent (or reset the
-- window of) a real event's budget, and two resources picking one name shared it.
exports('RateOk', function(src, name, windowMs, maxHits)
    if (type(name) == 'string' and name ~= '') or (type(name) == 'number' and isFinite(name)) then
        name = ('export:%s:%s'):format(GetInvokingResource() or 'cis_libs', tostring(name))
    end
    return rateOk(src, name, windowMs, maxHits)
end)

exports('SecurityReport', CisSecurityReport)

exports('GetLibsPrefix', function()
    return (Security and Security.EventPrefix) or 'cis_libs'
end)

-- A resource that stops takes its net bindings with it ().
-- Through CisOnResourceStop (shared/owned.lua), so a forged stop is ignored.
CisOnResourceStop(function(resource)
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
    return { srcs = total, cap = RATE_BUCKET_CAP, nonPlayer = nonPlayerCount, nonPlayerCap = NONPLAYER_SRC_CAP }
end)
