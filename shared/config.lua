-- Client config whitelist. Webhooks, drop-player hooks, and allow-lists stay server-side.

CisConfigUtil = {}

local function copyPublic(value)
    local valueType = type(value)
    if valueType == 'function' then
        return nil
    end
    if valueType ~= 'table' then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        local copied = copyPublic(v)
        if copied ~= nil or type(v) ~= 'function' then
            if type(v) ~= 'function' then
                out[k] = copied
            end
        end
    end
    return out
end

function CisConfigUtil.clientPayload(config, security, doorData)
    config = config or {}
    security = security or {}
    local framework = config.Framework or {}
    return {
        Config = {
            UpdateInterval = copyPublic(config.UpdateInterval) or {
                Player = 250,
                Vehicle = 1000,
                VehicleProperties = 5000,
                Weapon = 250,
            },
            AimingCheckType = config.AimingCheckType or 'default',
            CallbackTimeout = config.CallbackTimeout or 10000,
            Framework = {
                Type = framework.Type or 'NONE',
                Inventory = framework.Inventory or 'typical',
                Zones = {
                    Enabled = not (framework.Zones and framework.Zones.Enabled == false),
                },
                Target = {
                    Enabled = not (framework.Target and framework.Target.Enabled == false),
                    Type = (framework.Target and framework.Target.Type) or 'ox_target',
                    Debug = (framework.Target and framework.Target.Debug) and true or false,
                },
            },
            Doorlock = {
                Enabled = not (config.Doorlock and config.Doorlock.Enabled == false),
                Type = (config.Doorlock and config.Doorlock.Type) or 'target',
                InteractableDistance = (config.Doorlock and config.Doorlock.InteractableDistance) or 2.0,
            },
            Printing = {
                Debug = config.Printing and config.Printing.Debug and true or false,
            },
            Sync = {
                Enabled = not (config.Sync and config.Sync.Enabled == false),
            },
        },
        EventPrefix = (security.EventPrefix or 'cis_libs'),
        DoorData = doorData or { doors = {}, groups = {} },
    }
end

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
