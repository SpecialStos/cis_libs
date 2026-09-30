-- Client config whitelist. Webhooks, drop-player hooks, and allow-lists stay server-side.
--
-- PURE, and safe for a consumer to `shared_script` (COMPATIBILITY.md §10.2) --
-- but the reason to want it is usually to READ the payload shape, not to
-- generate it. Everything the client is told is written out by hand below, so a
-- key added to the server config does not reach a client until someone adds it
-- to this table. That is the point: a client has no business holding a webhook
-- URL or an allow-list.

CisConfigUtil = {}

-- Drops functions, recursively. A function cannot cross the exports/net-event
-- boundary, so one left in here would arrive as nil and would have looked like
-- a config bug on the client rather than a stripping rule here.
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

-- The defaults here are a floor, not the shipped values. configs/master_config.lua
-- sets UpdateInterval explicitly, and a client reading that gets 1000ms. These
-- 250ms values only apply if a config arrives without them, so the two must not
-- be read as "the default".
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

-- The assertion that the hand-built payload above has not drifted. It is not
-- how secrets are kept out -- the whitelist already has no slot for them -- it
-- is what makes a future careless key fail the suite instead of shipping to
-- every connected client.
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
