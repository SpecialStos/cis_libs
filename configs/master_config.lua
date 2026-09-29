Config = {}

Config.CheckVersion = true -- Prints on console and logs it in Master Logs.

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
