Config = {}

Config.CheckVersion = true --Checks if you are running the latest version of the script. Prits on console and logs it in Master Logs.

Config.Framework = "NONE" --Set this to your framework. "ESX" - "QBCORE" - "QBOX - "NONE"

Config.Debug = false --Enables/Disables debug mode

Config.UpdateInterval = {
    Player = 100,
    Vehicle = 500
}

-- Database configuration (if needed)
Config.Database = {
    Type = "mysql", -- or "mongodb", etc.
    Name = "your_database_name",
    -- Add other database config options as needed
}