Config = {}

-- Off by default, and that is a security decision, not an oversight.
--
-- When this was on, every single boot fired an outbound HTTPS GET to a
-- hardcoded personal GitHub Pages URL, unconditionally and with no operator
-- opt-in. That is three problems at once:
--
--   * supply chain -- a third party who controls that host controls what this
--     library tells the operator it is, and any script content it chooses to
--     echo into a WARN line. A commercial product should not phone home.
--   * air-gapped and offline servers -- the request has no timeout of its own
--     and the boot thread waits on it.
--   * consent -- a server owner was never asked.
--
-- The endpoint is a CIsoko-controlled path that does not resolve yet, so even
-- a server that opts in before the endpoint is published gets a failed request
-- and the existing "Version check failed; continuing startup." warning, with
-- nothing leaving the machine that matters. Point this at your own mirror to
-- use the feature; leave it off for a production posture.
Config.CheckVersion = false

-- Only read when Config.CheckVersion is true. No third-party host is named
-- anywhere in this resource any more -- the previous hardcoded URL was a
-- personal GitHub Pages address and has been removed.
Config.VersionCheckUrl = "https://api.cisoko.net/v1/cis_libs/version.txt"

Config.CallbackTimeout = 10000

-- Fallback poll interval in milliseconds. The cache is primarily event-driven;
-- this loop only catches what events miss (respawn, seat change without a
-- game event, weapon swap). Each tick costs roughly ten natives plus a vec4
-- allocation, so lowering Player trades idle cost for fresher Globals.
Config.UpdateInterval = {
    Player = 1000,
    Weapon = 1000,
    -- Read by a consumer that syncs vehicle properties; this resource does not
    -- poll them on its own.
    Vehicle = 1000,
    VehicleProperties = 5000,
}

Config.AimingCheckType = "default" -- "default" or "configFlag"

Config.Framework = {
    Type = "QBCORE", -- "ESX", "ESX-LEGACY", "QBCORE", "QBOX", or "NONE"
    Inventory = "ox_inventory", -- "ox_inventory", "qb-inventory", "qs-inventory", "codem-inventory", or "typical"
    Zones = {
        Enabled = true,
    },
    Target = {
        Enabled = true,
        Type = "ox_target", -- "qb-target" / "ox_target"
        Debug = false,
    },
    Database = {
        Type = "oxmysql", -- "oxmysql", "mysql-async", "ghmattimysql", "mongodb"
        Collection = nil, -- Required only for MongoDB.
        Timeout = 15000, -- ms before an awaited query gives up and returns nil.
    }
}

Config.Doorlock = {
    Enabled = true,
    Type = "target", -- DrawText3D / target
    InteractableDistance = 2.0,
    Persist = false, -- SQL only. Creates cis_doors if the database driver is ready.
}

Config.Sync = {
    Enabled = true,
}

Config.Printing = {
    Debug = false,
    UseDiscordLogs = false
}
