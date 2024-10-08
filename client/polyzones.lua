-- cis_libs/client/polyzones.lua

local Polyzones = {}
local activePolyzones = {}

-- Initialize the polyzone system based on the config
Citizen.CreateThread(function()
    while Config == nil do
        Citizen.Wait(100)
    end

    if not Config.Framework.Zones.Enabled then
        print("Polyzone system is disabled in the config.")
        return
    end

    if Config.Framework.Zones.Type == "polyzones" then
        -- Ensure PolyZone is available
        if PolyZone == nil then
            print("Error: PolyZone library not found. Make sure it's properly installed.")
            return
        end
    elseif Config.Framework.Zones.Type == "ox-lib" then
        -- Ensure ox_lib is available
        if lib == nil or lib.zones == nil then
            print("Error: ox-lib not found or zones module not available. Make sure it's properly installed.")
            return
        end
    else
        print("Error: Invalid zone type specified in config. Use 'polyzones' or 'ox-lib'.")
        return
    end

    --print("Polyzone system initialized using " .. Config.Framework.Zones.Type)
end)

-- Function to create a new polyzone
function Polyzones.Create(name, points, options)
    -- Check if polyzone system is enabled
    if not Config.Framework.Zones.Enabled then
        exports['cis_libs']:LogWarn("Polyzone system is disabled. Skipping creation of zone: " .. name)
        return
    end

    -- Check if polyzone already exists
    if activePolyzones[name] then
        exports['cis_libs']:LogWarn("Polyzone '" .. name .. "' already exists. Use Update to modify it.")
        return
    end

    local newZone
    if Config.Framework.Zones.Type == "polyzones" then
        -- Create zone using PolyZone library
        newZone = PolyZone:Create(points, {
            name = name,
            minZ = options.minZ,
            maxZ = options.maxZ,
            debugPoly = options.debug
        })
        exports['cis_libs']:LogDebug("Created PolyZone: " .. name)
    elseif Config.Framework.Zones.Type == "ox-lib" then
        -- Ensure points is a table of vector3
        local convertedPoints = {}
        for _, point in ipairs(points) do
            if type(point) == "vector3" then
                table.insert(convertedPoints, point)
            elseif type(point) == "vector2" then
                table.insert(convertedPoints, vector3(point.x, point.y, options.minZ or 0))
            elseif type(point) == "table" and #point >= 2 then
                table.insert(convertedPoints, vector3(point[1], point[2], options.minZ or 0))
            else
                exports['cis_libs']:LogError("Invalid point format for ox_lib zone: " .. name)
                return
            end
        end

        -- Create zone using ox_lib
        newZone = lib.zones.poly({
            name = name,
            points = convertedPoints,
            thickness = (options.maxZ or 4) - (options.minZ or 0),
            debug = options.debug,
            onEnter = function(self)
                if options.onEnter then
                    local status, err = pcall(options.onEnter, self)
                    if not status then
                        exports['cis_libs']:LogError("Error in onEnter callback for zone " .. name .. ": " .. tostring(err))
                    end
                end
            end,
            onExit = function(self)
                if options.onExit then
                    local status, err = pcall(options.onExit, self)
                    if not status then
                        exports['cis_libs']:LogError("Error in onExit callback for zone " .. name .. ": " .. tostring(err))
                    end
                end
            end,
            inside = options.inside
        })
        exports['cis_libs']:LogDebug("Created ox_lib zone: " .. name)
    else
        exports['cis_libs']:LogError("Invalid zone type specified in config for zone: " .. name)
        return
    end

    -- Store the created zone
    activePolyzones[name] = {
        zone = newZone,
        options = options
    }

    exports['cis_libs']:LogInfo("Created polyzone: " .. name)
    return newZone
end

-- Function to remove a polyzone
function Polyzones.Remove(name)
    if not Config.Framework.Zones.Enabled then return end
    if not activePolyzones[name] then
        print("Warning: Polyzone '" .. name .. "' not found.")
        return
    end

    if Config.Framework.Zones.Type == "polyzones" then
        activePolyzones[name].zone:destroy()
    elseif Config.Framework.Zones.Type == "ox-lib" then
        activePolyzones[name].zone:remove()
    end

    activePolyzones[name] = nil
    --print("Removed polyzone: " .. name)
end

-- Function to check if a point is inside a polyzone
function Polyzones.IsPointInside(name, point)
    if not Config.Framework.Zones.Enabled then 
        exports['cis_libs']:LogWarn("Polyzone system is disabled. IsPointInside check skipped for: " .. tostring(name))
        return false 
    end
    
    if not activePolyzones[name] then
        exports['cis_libs']:LogError("Polyzone '" .. tostring(name) .. "' not found in IsPointInside check")
        return false
    end

    -- Ensure point is vector3
    local checkPoint = type(point) == "vector3" and point or vector3(point.x, point.y, point.z)

    if Config.Framework.Zones.Type == "polyzones" then
        return activePolyzones[name].zone:isPointInside(checkPoint)
    elseif Config.Framework.Zones.Type == "ox-lib" then
        -- ox_lib zones use a different method to check if a point is inside
        return activePolyzones[name].zone:contains(checkPoint)
    end

    exports['cis_libs']:LogError("Invalid zone type in IsPointInside check for: " .. tostring(name))
    return false
end

-- Export the Polyzones table
exports('GetPolyzones', function()
    return Polyzones
end)

return Polyzones