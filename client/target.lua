-- cis_libs/client/target.lua

local Target = {}
local CreatedZones = {}

local function ensureConfig()
    if Config == nil then
        --print("Config is nil, waiting...")
        while Config == nil do
            Citizen.Wait(100)
        end
        --print("Config loaded")
    end
end

Target.Create = function(zoneType, name, coords, size, options)
    --print(name)
    ensureConfig()
    if not Config.Framework.Target.Enabled then
        return false
    end
    if type(name) ~= "string" then
        return false
    end

    local targetOptions = {
        options = options.options or {},
        distance = options.distance or 2.0
    }

    local success = false

    if Config.Framework.Target.Type == "ox_target" then
        if zoneType == "sphere" then
            exports.ox_target:addSphereZone({
                name = name,
                coords = coords,
                radius = size,
                options = targetOptions.options,
                debug = Config.Framework.Target.Debug
            })
            success = true
        elseif zoneType == "box" then
            exports.ox_target:addBoxZone({
                name = name,
                coords = coords,
                size = size,
                rotation = options.rotation or 0,
                options = targetOptions.options,
                debug = Config.Framework.Target.Debug
            })
            success = true
        elseif zoneType == "ped" then
            exports.ox_target:addLocalEntity(options.entity, targetOptions.options)
            success = true
        end
    elseif Config.Framework.Target.Type == "qb-target" then
        if zoneType == "sphere" then
            exports['qb-target']:AddCircleZone(name, coords, size, {
                name = name,
                debugPoly = Config.Framework.Target.Debug
            }, targetOptions)
            success = true
        elseif zoneType == "box" then
            exports['qb-target']:AddBoxZone(name, coords, size[1], size[2], {
                name = name,
                heading = options.rotation or 0,
                debugPoly = Config.Framework.Target.Debug,
                minZ = coords.z - size[3]/2,
                maxZ = coords.z + size[3]/2
            }, targetOptions)
            success = true
        elseif zoneType == "ped" then
            exports['qb-target']:AddTargetEntity(options.entity, {
                options = targetOptions.options,
                distance = targetOptions.distance
            })
            success = true
        end
    end

    if success then
        CreatedZones[name] = {
            zoneType = zoneType,
            coords = coords,
            size = size,
            options = options
        }
    end

    return success
end

Target.Remove = function(name, isPed)
    ensureConfig()
    --print("cis_libs Target.Remove called for: " .. tostring(name))
   
    local success = false
   
    if Config.Framework.Target.Type == "ox_target" then
        if isPed then
            if CreatedZones[name] and CreatedZones[name].options and CreatedZones[name].options.entity then
                success = exports.ox_target:removeLocalEntity(CreatedZones[name].options.entity)
            else
                --print("Failed to remove ped target: Entity not found for " .. name)
            end
        else
            success = exports.ox_target:removeZone(name)
        end
    elseif Config.Framework.Target.Type == "qb-target" then
        if isPed then
            if CreatedZones[name] and CreatedZones[name].options and CreatedZones[name].options.entity then
                success = exports['qb-target']:RemoveTargetEntity(CreatedZones[name].options.entity)
            else
                --print("Failed to remove ped target: Entity not found for " .. name)
            end
        else
            success = exports['qb-target']:RemoveZone(name)
        end
    end
   
    if success then
        --print("Removed target: " .. name)
        CreatedZones[name] = nil
    else
        --print("Failed to remove target: " .. name)
    end
   
    return success
end

Target.Update = function(name, newOptions)
    ensureConfig()
    --print("cis_libs Target.Update called for: " .. tostring(name))
    
    local success = false
    
    if not CreatedZones[name] then
        --print("Target zone not found: " .. name)
        return false
    end
    
    local zoneInfo = CreatedZones[name]
    
    if Config.Framework.Target.Type == "ox_target" then
        success = exports.ox_target:removeZone(name)
        if success then
            success = Target.Create(zoneInfo.zoneType, name, zoneInfo.coords, zoneInfo.size, newOptions)
        end
    elseif Config.Framework.Target.Type == "qb-target" then
        exports['qb-target']:RemoveZone(name)
        success = Target.Create(zoneInfo.zoneType, name, zoneInfo.coords, zoneInfo.size, newOptions)
    end
    
    if success then
        --print("Updated target: " .. name)
        CreatedZones[name].options = newOptions
    else
        --print("Failed to update target: " .. name)
    end
    
    return success
end

Target.Exists = function(name)
    ensureConfig()
    --print("cis_libs Target.Exists called for: " .. tostring(name))
    
    local exists = CreatedZones[name] ~= nil
    
    --print(exists and "Target exists: " .. name or "Target does not exist: " .. name)
    
    return exists
end

-- Export individual functions
exports('CreateTarget', function(...)
    return Target.Create(...)
end)

exports('RemoveTarget', function(...)
    return Target.Remove(...)
end)

exports('UpdateTarget', function(...)
    return Target.Update(...)
end)

exports('TargetExists', function(...)
    return Target.Exists(...)
end)

--print("cis_libs target.lua loaded and exports set up")