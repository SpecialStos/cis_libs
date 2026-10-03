-- Built-in defaults, so this library runs with nothing configured.
--
-- cis_libs owns no config file. It used to: `configs/master_config.lua` and
-- `configs/security_config.lua` shipped here, which meant a fresh clone had two
-- editable files that were simultaneously documentation and load-bearing state,
-- and every consumer who copied one out of a support thread silently forked
-- their own copy of the library's behaviour.
--
-- The fix is that a library states its defaults in code, where they cannot be
-- edited by accident, and a PRODUCT ships the file an operator actually wants
-- to edit. cis_core ships that file. This table is the floor underneath it: a
-- server with cis_libs alone gets exactly these values, and a server with
-- cis_core installed gets whatever the operator wrote, key by key.
--
-- These are the values that were already the shipped defaults in
-- configs/master_config.lua. They are reproduced here unchanged on purpose --
-- an operator's server must not behave differently because the library was
-- reorganised underneath it. Where a value is a SECURITY decision, the reason
-- travels with it, because the reason is the part that stops the next person
-- from flipping it on a production server.

CisDefaults = {}

--- A fresh Config table. Fresh every call, so a consumer that mutates the
--- global it was handed cannot corrupt the defaults for the next caller.
function CisDefaults.config()
    return {
        -- SECURITY. OFF, and that is the decision rather than an oversight.
        -- When this was on, every boot fired an HTTPS GET to a hardcoded host
        -- unconditionally. Three problems at once: whoever controls the
        -- endpoint controls what this library claims its own version is and
        -- can echo script content into an operator's console; the request
        -- carries no timeout and boot waits on it; and nobody was asked. A
        -- commercial product should not phone home. Leave it false.
        CheckVersion = false,
        VersionCheckUrl = 'https://api.cisoko.net/v1/cis_libs/version.txt',

        -- How long a server->client callback waits before giving up. Generous on
        -- purpose: it costs nothing while idle, because a callback only starts
        -- its clock when one is actually sent. LOWERING it is the risky
        -- direction -- a nil that means "too early" is indistinguishable from a
        -- nil that means "no such thing".
        CallbackTimeout = 10000,

        -- Fallback poll interval for the client cache. Primarily event-driven;
        -- this is the safety net for what events miss. Each tick costs roughly
        -- ten natives per player, so 1000 is already aggressive on a busy
        -- server and 2000-3000 is usually indistinguishable in game.
        UpdateInterval = {
            Player = 1000,
            Weapon = 1000,
            Vehicle = 1000,
            VehicleProperties = 5000,
        },

        -- 'default' reads IsPlayerFreeAiming(), which is the real game state.
        -- 'configFlag' reads a ped config flag, which is NOT the aiming state on
        -- current builds and reports aiming false almost always. Kept for
        -- frameworks that replace player peds, not for a stock ped.
        AimingCheckType = 'default',

        -- Every value under Framework is a NAME OF A RESOURCE to look for, never
        -- a connection string and never a database name. AUTO asks the server
        -- what is actually running rather than trusting the configured name.
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
                -- MongoDB only. The library creates no table, so there is no
                -- collection for it to name; a product that stores anything
                -- brings its own.
                Collection = nil,
                -- Milliseconds before an awaited query gives up and yields nil.
                -- Raising it only makes a stalled query hang longer; lowering it
                -- makes slow queries look like missing ones.
                Timeout = 15000,
            },
        },

        Sync = {
            Enabled = true,
        },

        Printing = {
            -- Extra diagnostics on top of normal output. Verbose by design, and
            -- some of it is per-zone and per-entity.
            Debug = false,
            -- SECURITY: master switch for everything outbound. While false
            -- nothing is ever sent anywhere, so a placeholder webhook URL is
            -- inert no matter what it contains. Turning this ON makes whatever
            -- URLs are configured a live secret -- anyone holding one can read
            -- the channel, and for the error and cheating channels can post
            -- into it.
            UseDiscordLogs = false,
        },
    }
end

--- A fresh Security table. Separate from config() because the two are
--- redacted differently: the client is told a handful of config keys and the
--- event prefix, and nothing at all of this.
function CisDefaults.security()
    return {
        -- The prefix on every net event this library uses, on both sides.
        -- Keep it: it is the name this library publishes its events under, and
        -- the compiled-in fallback in client/ and server/ is the same string.
        --
        -- IF YOU CHANGE IT, every event name changes with it, and any companion
        -- resource that triggers these events directly must change in the same
        -- edit or it will stop working with no error -- the trigger is not
        -- refused, it simply never arrives. Only change it if two
        -- cis_libs-derived resources must coexist and their event sets collide.
        EventPrefix = 'cis_libs',

        -- RESERVED. Nothing reads it; Config.Printing.Debug is the flag that is
        -- actually wired up. Kept so an existing config keeps loading. Do not
        -- build anything on it -- setting it true turns nothing on.
        Debug = false,

        -- Who may register doors, break doors, write sync records, and register
        -- capabilities. EMPTY MEANS NOBODY. That is the intended default and it
        -- is not a bug: a new server has no authorised callers yet, so the
        -- honest answer to "who may mutate doors?" is nobody. Defaulting to
        -- allow-all would help nobody during setup and would leave the exposure
        -- in place afterwards.
        AuthorizedResources = {},

        -- THE ESCAPE HATCH, AND IT IS OFF (DEC-2).
        --
        -- An empty AuthorizedResources is ALWAYS restrictive, with no legacy
        -- exception and nothing left to classify. This key is how an operator
        -- who genuinely wants the old behaviour -- any server-side resource may
        -- mutate doors and sync records -- says so out loud.
        --
        -- Off by default, because a permissive default is the exact defect this
        -- replaces. The failure was never that the permissive behaviour was
        -- unreachable; it was that it was what you got without asking. Setting
        -- this is one deliberate line in the operator's own config, and every
        -- boot says so on the console while it is on.
        --
        -- A NAMED AuthorizedResources still governs when both are set, so the
        -- more careful configuration is never the weaker one.
        AllowAnyResource = false,

        -- SECURITY. A custom handler is a function, and a function cannot cross
        -- the exports boundary -- so this stays `true` in cis_libs and the real
        -- handler is supplied by whoever ships the config, server-side.
        --
        -- The message on the shipped default is deliberately generic and
        -- deliberately tells the player to contact the server owner. Naming the
        -- check that fired tells a person exactly which guard to look for, and
        -- guards are the first thing somebody wants to find.
        DropPlayer = true,
    }
end

--- Deep copy, with functions dropped. A function cannot cross the exports
--- boundary, so a config table that arrives from another resource may legally
--- contain one -- and if it lands in cis_libs's own globals it would be a
--- callable that the client can never receive and the server cannot serialise.
--- Dropping them at the boundary is the same rule the client payload already
--- applies, applied one level earlier.
function CisDefaults.sanitize(value, depth)
    if type(value) ~= 'table' then
        return value
    end
    depth = depth or 0
    -- A config that nests further than this is a mistake, and an unbounded
    -- recursive copy of a caller-supplied table is a denial-of-service surface.
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

--- Merge an operator's config over the defaults, key by key, recursing into
--- tables. An operator who sets `Config.Framework.Target.Debug = true` gets the
--- rest of the Target table from the defaults rather than a table with one key
--- in it, which is what naive `or` chains produce and why a half-written config
--- used to blank out unrelated settings.
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

-- What a value has to satisfy to be accepted. One table so that "why was my
-- config refused" and "what values are legal" are the same lookup, and so a
-- new field cannot be added to the defaults without someone deciding whether it
-- is validated.
--
-- `CisDefaults.validate` is deliberately NOT exhaustive: it checks the values
-- whose failure mode is SILENT. A bad `CallbackTimeout` does not raise -- it
-- makes every callback wait forever, or never wait, and the caller sees a nil
-- that reads like "no such row". A bad `AimingCheckType` does not raise either;
-- it falls through to the default and the server reports aiming as false
-- almost always, which looks like a game bug rather than a typo.
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

-- `{ name = check, path = <dotted path into Config>, ok = <check>}`. The path is
-- written out rather than derived so a message can name the exact key an
-- operator has to edit, which is the whole value of a refusal.
local CONFIG_RULES = {
    { path = 'CallbackTimeout', ok = between(1000, 60000) },
    { path = 'UpdateInterval.Player', ok = between(100, 10000) },
    { path = 'UpdateInterval.Weapon', ok = between(100, 10000) },
    { path = 'UpdateInterval.Vehicle', ok = between(100, 10000) },
    { path = 'UpdateInterval.VehicleProperties', ok = between(100, 60000) },
    { path = 'AimingCheckType', ok = oneOf({ 'default', 'configFlag' }) },
    { path = 'Framework.Database.Timeout', ok = between(1000, 120000) },
}

--- Check a config, and report EVERY problem rather than the first.
---
--- `SetConfig` merges a table that arrived across the exports boundary from
--- another resource, and nothing about the values was checked. A negative
--- `CallbackTimeout` or an `UpdateInterval` of zero does not fail loudly at the
--- point of the mistake -- it produces a callback that never times out, or a
--- client loop that spins at the frame rate, hours later, somewhere else.
---
--- This is a REFUSAL with a reason rather than a raise, and it refuses the whole
--- config rather than half-applying it: a partially applied security policy is
--- worse than a rejected one, because the operator cannot tell which half took
--- effect.
---
--- Returns `true`, or `false` plus a list of messages. Each message names the
--- key, what is wrong with it, and what would be acceptable -- the three things
--- somebody needs in order to fix a line in their config without opening a
--- support thread.
---
--- @param config table  the RESOLVED config (post-merge), not the override
--- @return boolean ok
--- @return table|nil problems  an array of strings, empty when ok
function CisDefaults.validate(config)
    local problems = {}
    if type(config) ~= 'table' then
        return false, { ('config must be a table, got %s'):format(type(config)) }
    end
    for _, rule in ipairs(CONFIG_RULES) do
        -- Walked explicitly rather than with a lookup table, because `nil` is a
        -- legitimate stored value for a path that does not exist and a missing
        -- key is not a validation failure -- it just means the defaults apply.
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
