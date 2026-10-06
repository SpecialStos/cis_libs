-- Built-in defaults, so this library runs with nothing configured.

CisDefaults = {}

--- A fresh Config table. Fresh every call, so a consumer that mutates the global it was
function CisDefaults.config()
    return {
        -- SECURITY. OFF, and that is the decision rather than an oversight.
        CheckVersion = false,
        VersionCheckUrl = 'https://api.cisoko.net/v1/cis_libs/version.txt',

        -- How long a server->client callback waits before giving up.
        CallbackTimeout = 10000,

        -- Fallback poll interval for the client cache.
        UpdateInterval = {
            Player = 1000,
            Weapon = 1000,
            Vehicle = 1000,
            VehicleProperties = 5000,
        },

        -- How many capability and configuration events the in-memory audit ring keeps
        AuditLines = 500,

        -- 'default' reads IsPlayerFreeAiming(), which is the real game state.
        AimingCheckType = 'default',

        -- Every value under Framework is a NAME OF A RESOURCE to look for, never a
        Framework = {
            Type = 'AUTO',
            Inventory = 'ox_inventory',
            Zones = {
                Enabled = true,
            },
            Target = {
                Enabled = true,
                Type = 'ox_target',
                -- Noisy by design and it prints zone and door identifiers.
                Debug = false,
            },
            Database = {
                Type = 'AUTO',
                -- MongoDB only. The library creates no table, so there is no collection
                Collection = nil,
                -- Milliseconds before an awaited query gives up and yields nil.
                Timeout = 15000,
            },
        },

        Sync = {
            Enabled = true,
        },

        Printing = {
            -- Extra diagnostics on top of normal output.
            Debug = false,
            -- SECURITY: master switch for everything outbound.
            UseDiscordLogs = false,
        },
    }
end

--- A fresh Security table. Separate from config() because the two are redacted
function CisDefaults.security()
    return {
        -- The prefix on every net event this library uses, on both sides.
        EventPrefix = 'cis_libs',

        -- RESERVED. Nothing reads it; Config.Printing.Debug is the flag that is
        Debug = false,

        -- Who may register doors, break doors, write sync records, and register
        AuthorizedResources = {},

        -- THE ESCAPE HATCH, AND IT IS OFF .
        AllowAnyResource = false,

        -- SECURITY. A custom handler is a function, and a function cannot cross the
        DropPlayer = true,
    }
end

--- Deep copy, with functions dropped.
function CisDefaults.sanitize(value, depth)
    if type(value) ~= 'table' then
        return value
    end
    depth = depth or 0
    -- A config that nests further than this is a mistake, and an unbounded recursive
    if depth > 12 then
        return nil
    end
    local out = {}
    for k, v in pairs(value) do
        if type(v) ~= 'function' then
            out[k] = CisDefaults.sanitize(v, depth + 1)
        end
    end
    return out
end

--- Merge an operator's config over the defaults, key by key, recursing into tables.
function CisDefaults.merge(base, override)
    if type(override) ~= 'table' then
        return base
    end
    for k, v in pairs(override) do
        if type(v) == 'table' and type(base[k]) == 'table' then
            base[k] = CisDefaults.merge(base[k], v)
        elseif v ~= nil then
            base[k] = v
        end
    end
    return base
end

-- What a value has to satisfy to be accepted.
local function between(lo, hi)
    return function(v)
        if type(v) ~= 'number' then
            return ('must be a number, got %s'):format(type(v))
        end
        if v ~= v then
            return 'must be a number, got NaN'
        end
        if v < lo or v > hi then
            return ('must be between %d and %d, got %s'):format(lo, hi, tostring(v))
        end
        return nil
    end
end

local function oneOf(choices)
    return function(v)
        for _, c in ipairs(choices) do
            if v == c then
                return nil
            end
        end
        return ("must be one of %s, got %s"):format(table.concat(choices, ', '), tostring(v))
    end
end

-- A check returns NIL when the value is acceptable and a STRING when it is not.
local function boolean(v)
    if type(v) ~= 'boolean' then
        return ('must be true or false, got %s (%s)'):format(type(v), tostring(v))
    end
    return nil
end

local function nonEmptyString(v)
    if type(v) ~= 'string' or #v == 0 then
        return ('must be a non-empty string, got %s (%s)'):format(type(v), tostring(v))
    end
    return nil
end

-- `{ name = check, path = <dotted path into Config>, ok = <check>}`.
local CONFIG_RULES = {
    { path = 'CallbackTimeout', ok = between(1000, 60000) },
    { path = 'AuditLines', ok = between(1, 10000) },
    { path = 'UpdateInterval.Player', ok = between(100, 10000) },
    { path = 'UpdateInterval.Weapon', ok = between(100, 10000) },
    { path = 'UpdateInterval.Vehicle', ok = between(100, 10000) },
    { path = 'UpdateInterval.VehicleProperties', ok = between(100, 60000) },
    { path = 'AimingCheckType', ok = oneOf({ 'default', 'configFlag' }) },
    { path = 'Framework.Database.Timeout', ok = between(1000, 120000) },
    -- BOOLEANS THAT GATE A SUBSYSTEM.
    { path = 'CheckVersion', ok = boolean },
    -- Config.Doorlock.Enabled: validated boolean; no current reader after the door
    -- exports moved to the capability slot.
    { path = 'Doorlock.Enabled', ok = boolean },
    { path = 'Framework.Target.Enabled', ok = boolean },
    { path = 'Framework.Target.Debug', ok = boolean },
    { path = 'Framework.Zones.Enabled', ok = boolean },
    { path = 'Printing.Debug', ok = boolean },
    { path = 'Printing.UseDiscordLogs', ok = boolean },
    { path = 'Sync.Enabled', ok = boolean },
    { path = 'VersionCheckUrl', ok = nonEmptyString },
    { path = 'Framework.Type', ok = oneOf({ 'ESX', 'QBCore', 'QBox', 'ND_Core', 'AUTO' }) },
}

-- READ BY THE CODE, DELIBERATELY NOT VALIDATED, each for a reason.
local FREE_TEXT = {
    ['DiscordLogsLinks'] = 'a map of free-text webhook URLs; cis_libs never interprets them, '
        .. 'and rejecting a malformed URL would refuse a config the operator can see is fine',
    ['Framework.Custom'] = 'a product-owned escape hatch, opaque to cis_libs by design',
    ['Framework.Target.Type'] = 'a target type STRING chosen by the product that registers the '
        .. 'target capability; cis_libs cannot enumerate values it does not own',
    ['__owner'] = 'internal: which resource supplied this config. Written by SetConfig.',
    ['__owned'] = 'internal: the config owner ledger. Written by SetConfig.',
}

-- EXPOSED, because they are a contract and not an implementation detail:
CisDefaults.CONFIG_RULES = CONFIG_RULES
CisDefaults.FREE_TEXT = FREE_TEXT

-- There is no empty list on the success path: a clean config answers a bare `true` and
--- Check a config, and report EVERY problem rather than the first.
--- @param config table  the RESOLVED config (post-merge), not the override
--- @return boolean ok
--- @return table|nil problems  an array of strings, PRESENT ONLY ON FAILURE.
function CisDefaults.validate(config)
    local problems = {}
    if type(config) ~= 'table' then
        return false, { ('config must be a table, got %s'):format(type(config)) }
    end
    for _, rule in ipairs(CONFIG_RULES) do
        -- Walked explicitly rather than with a lookup table, because `nil` is a
        local node = config
        for segment in rule.path:gmatch('[^.]+') do
            node = type(node) == 'table' and node[segment] or nil
            if node == nil then
                break
            end
        end
        if node ~= nil then
            local why = rule.ok(node)
            if why then
                problems[#problems + 1] = ('Config.%s %s'):format(rule.path, why)
            end
        end
    end
    if #problems > 0 then
        return false, problems
    end
    return true
end
