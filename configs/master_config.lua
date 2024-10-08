Config = {}

Config.CheckVersion = true --Checks if you are running the latest version of the script. Prits on console and logs it in Master Logs.

Config.UpdateInterval = { --in milliseconds
    Player = 100,
    Vehicle = 1000000, --disabled for v0.1.0, next update will have this feature for TCVS.
    Weapon = 250,
}

-- Framework configuration
Config.Framework = {
    Type = "QBCORE", -- Set this to your framework. "ESX", "ESX-LEGACY", "QBCORE", "QBOX", or "NONE"
    Inventory = "ox_inventory", -- Set this to your inventory system. "ox_inventory", "qb-inventory", "qs-inventory", "codem-inventory", or "typical"
    Zones = {
        Enabled = true,
        Type = "ox-lib", -- "polyzones" / "ox-lib"
    },
    Target = {
        Enabled = true,
        Type = "ox_target", -- "qb-target" / "ox_target"
    },
    Database = {
        Type = "oxmysql", -- "mysql-async", "ghmattimysql", "mongodb".
    }
}

Config.Doorlock = {
    Enabled = true,
    Type = "target", -- DrawText3D / target
    InteractableDistance = 2.0,
}

Config.Printing = {
    Debug = false, -- Enables/Disables debug mode
    UseDiscordLogs = false -- Enables/Disables Discord logging
}