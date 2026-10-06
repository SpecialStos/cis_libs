-- Configuration intake and the client redaction whitelist.

CisConfigUtil = {}

-- THE CLIENT FALLBACKS COME FROM CisDefaults, NOT FROM A SECOND COPY.
local function clientIntervals(config)
    local defaults = CisDefaults.config().UpdateInterval
    local supplied = config.UpdateInterval
    local out = {}
    for _, key in ipairs({ 'Player', 'Weapon', 'Vehicle', 'VehicleProperties' }) do
        -- Key by key rather than merging the whole table: a partial UpdateInterval keeps other defaults.
        local v = type(supplied) == 'table' and supplied[key]
        out[key] = (type(v) == 'number' and v) or defaults[key]
    end
    return out
end

-- The defaults here are a FLOOR, not the shipped values.
function CisConfigUtil.clientPayload(config, security)
    config = config or {}
    security = security or {}
    local framework = config.Framework or {}
    local defaults = CisDefaults.config()
    return {
        Config = {
            UpdateInterval = clientIntervals(config),
            AimingCheckType = config.AimingCheckType or defaults.AimingCheckType,
            CallbackTimeout = config.CallbackTimeout or defaults.CallbackTimeout,
            Framework = {
                -- 'NONE' rather than 'AUTO' on the client, deliberately.
                Type = framework.Type or 'NONE',
                Inventory = framework.Inventory or 'ox_inventory',
                Zones = {
                    Enabled = not (framework.Zones and framework.Zones.Enabled == false),
                },
                Target = {
                    Enabled = not (framework.Target and framework.Target.Enabled == false),
                    Type = (framework.Target and framework.Target.Type) or 'ox_target',
                    Debug = (framework.Target and framework.Target.Debug) and true or false,
                },
            },
            Sync = {
                Enabled = not (config.Sync and config.Sync.Enabled == false),
            },
            Printing = {
                Debug = config.Printing and config.Printing.Debug and true or false,
            },
        },
        -- Only the prefix crosses. Not the allow-list, not the kick handler.
        EventPrefix = (security.EventPrefix or 'cis_libs'),
    }
end

-- The assertion that the hand-built payload above has not drifted.
function CisConfigUtil.containsSecret(payload)
    local blob = payload
    if type(payload) ~= 'string' then
        -- cheap structural check used by tests
        local function walk(v)
            if type(v) == 'function' then
                return true
            end
            if type(v) == 'string' then
                if v:find('discord.com/api/webhooks', 1, true) then
                    return true
                end
                if v:find('CHANGE-ME-WITH-YOUR-WEBHOOK', 1, true) then
                    return true
                end
            elseif type(v) == 'table' then
                if v.DiscordLogsLinks or v.DropPlayer or v.AuthorizedResources or v.Database then
                    return true
                end
                for _, child in pairs(v) do
                    if walk(child) then
                        return true
                    end
                end
            end
            return false
        end
        return walk(blob)
    end
    return false
end

-- Installs the built-in defaults into the two globals every module in this library
Config = CisDefaults.config()
Security = CisDefaults.security()

-- The configuration is ESTABLISHED, and stamped as belonging to cis_libs.
Config.__owned = true
Config.__owner = 'cis_libs'
