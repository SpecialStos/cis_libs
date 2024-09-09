-- cis_libs/config.lua

Config = {}

-- Debug mode
Config.Debug = false

-- Update intervals (in ms)
Config.UpdateInterval = {
    Player = 100,
    Vehicle = 500
}

-- Add any other configuration options here
Config.MaxDistance = 100.0 -- Example: maximum distance for certain operations

-- Framework selection (uncomment the one you're using)
-- Config.Framework = "ESX"
-- Config.Framework = "QBCore"
-- Config.Framework = "custom"

-- Database configuration (if needed)
Config.Database = {
    Type = "mysql", -- or "mongodb", etc.
    Name = "your_database_name",
    -- Add other database config options as needed
}