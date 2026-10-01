-- Configuration intake and the client redaction whitelist.
--
-- cis_libs owns no config file any more. `CisDefaults` states the floor and
-- whichever product is installed hands over the real table through
-- `exports['cis_libs']:SetConfig`. This file installs the floor at load, in
-- both realms, so nothing downstream ever has to nil-check `Config`.
--
-- The second half is the client whitelist, and it is the only place a server
-- decides what a connected player is told. Everything the client receives is
-- written out by hand below rather than copied, which is the point: a key added
-- to the server config does not reach a player until someone adds it here, and
-- a client has no business holding a webhook URL, a connection string or an
-- allow-list.

CisConfigUtil = {}

-- Drops functions, recursively. A function cannot cross the exports boundary,
-- so one left in here would arrive as nil and would have looked like a config
-- bug on the client rather than a stripping rule here.
local function copyPublic(value)
    if type(value) ~= 'table' then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        if type(v) ~= 'function' then
            out[k] = copyPublic(v)
        end
    end
    return out
end

-- THE CLIENT FALLBACKS COME FROM CisDefaults, NOT FROM A SECOND COPY.
--
-- They used to be literals written out here, and they had already drifted from
-- shared/defaults.lua: 250ms for Player and Weapon here against 1000ms there. A
-- client that never received a server payload -- which is every client on a
-- server whose getData answer has not landed yet, and every client for the whole
-- first second of a session -- ran its cache four times faster than the library
-- documents. Nothing reported it: the cache works either way, it just costs four
-- times the natives.
--
-- Deriving them means there is one place to change a default and no second copy
-- to forget. It does NOT mean copying CisDefaults wholesale: the whitelist below
-- is still written out key by key, and CheckVersion and VersionCheckUrl are in
-- CisDefaults and must stay on this side of the wire.
local function clientIntervals(config)
    local defaults = CisDefaults.config().UpdateInterval
    local supplied = config.UpdateInterval
    local out = {}
    for _, key in ipairs({ 'Player', 'Weapon', 'Vehicle', 'VehicleProperties' }) do
        -- Key by key rather than `supplied or defaults`: a config carrying
        -- `{ Player = 3000 }` must keep the OTHER THREE, not replace the whole
        -- table with a one-key table. That is the failure mode a naive `or` has,
        -- and it is the same one CisDefaults.merge exists to prevent.
        local v = type(supplied) == 'table' and supplied[key]
        out[key] = (type(v) == 'number' and v) or defaults[key]
    end
    return out
end

-- The defaults here are a FLOOR, not the shipped values. A server running
-- cis_libs alone gets exactly these; a server with cis_core installed gets
-- whatever the operator wrote, and these values are what any key they left out
-- falls back to. Read the two as different things -- the first is a default,
-- the second is a guarantee about what a partial config does not blank out.
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
                -- 'NONE' rather than 'AUTO' on the client, deliberately. The
                -- client has no framework of its own to detect, and sending AUTO
                -- would invite a consumer to branch on a value that was never
                -- resolved on this side of the wire.
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
        -- It is the one piece of Security a client-side module needs, for
        -- building the event names it has to trigger.
        EventPrefix = (security.EventPrefix or 'cis_libs'),
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

-- Installs the built-in defaults into the two globals every module in this
-- library reads. Runs in both realms from shared_scripts, so the client has a
-- Config to read before the server's payload arrives -- which means a client
-- module that starts early reads a real table rather than nil and caches that
-- nil forever. The server's payload overwrites both when it lands.
Config = CisDefaults.config()
Security = CisDefaults.security()

-- The configuration is ESTABLISHED, and stamped as belonging to cis_libs. That
-- stamp is what lets a product replace these defaults: SetConfig refuses a
-- second supplier, and "cis_libs" is not a supplier, it is the floor. A server
-- with no cis_core installed still has a real, complete, working Config, and
-- a client waiting on the handshake is released rather than timing out against
-- a library that has nothing left to wait for.
Config.__owned = true
Config.__owner = 'cis_libs'
