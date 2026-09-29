local Target = {}
local CreatedZones = {}
local warnedMissing = false

local function targetType()
    return Config and Config.Framework and Config.Framework.Target and Config.Framework.Target.Type or 'ox_target'
end

local function targetEnabled()
    return not (Config and Config.Framework and Config.Framework.Target and Config.Framework.Target.Enabled == false)
end

local function targetDebug()
    return Config and Config.Framework and Config.Framework.Target and Config.Framework.Target.Debug
end

local function resourceStarted(name)
    return GetResourceState(name) == 'started'
end

function Target.Available()
    if not targetEnabled() then
        return false
    end
    local kind = targetType()
    if kind == 'ox_target' then
        return resourceStarted('ox_target')
    end
    if kind == 'qb-target' then
        return resourceStarted('qb-target')
    end
    return false
end

local function missingOnce()
    if warnedMissing then
        return
    end
    warnedMissing = true
    CisLog('warn', 'Target provider is not started; falling back where possible')
end

Target.Create = function(zoneType, name, coords, size, options)
    -- Refusals return a reason as a second value: a caller across the exports
    -- boundary cannot read cis_libs's console output.
    if not CisReadyState.wait(15000) then
        return false, 'cis_libs never became ready'
    end
    options = options or {}
    if not targetEnabled() then
        return false, 'target disabled by config'
    end
    if type(name) ~= 'string' or name == '' then
        return false, ('name arrived as %s'):format(type(name))
    end
    if coords == nil then
        return false, 'coords arrived as nil (the exports boundary dropped them)'
    end
    if not Target.Available() then
        missingOnce()
        return false, 'no target provider started'
    end
    if zoneType ~= 'box' and zoneType ~= 'sphere' and zoneType ~= 'ped' then
        return false, ('unknown zoneType %s'):format(tostring(zoneType))
    end

    local targetOptions = {
        options = options.options or {},
        distance = options.distance or 2.0,
    }
    local success = false
    local kind = targetType()

    if kind == 'ox_target' then
        if zoneType == 'sphere' then
            exports.ox_target:addSphereZone({
                name = name,
                coords = coords,
                radius = size,
                options = targetOptions.options,
                debug = targetDebug(),
            })
            success = true
        elseif zoneType == 'box' then
            exports.ox_target:addBoxZone({
                name = name,
                coords = coords,
                size = size,
                rotation = options.rotation or 0,
                options = targetOptions.options,
                debug = targetDebug(),
            })
            success = true
        elseif zoneType == 'ped' then
            exports.ox_target:addLocalEntity(options.entity, targetOptions.options)
            success = true
        end
    elseif kind == 'qb-target' then
        if zoneType == 'sphere' then
            exports['qb-target']:AddCircleZone(name, coords, size, {
                name = name,
                debugPoly = targetDebug(),
            }, targetOptions)
            success = true
        elseif zoneType == 'box' then
            local sx = size.x or size[1] or 1.0
            local sy = size.y or size[2] or 1.0
            local sz = size.z or size[3] or 1.0
            exports['qb-target']:AddBoxZone(name, coords, sx, sy, {
                name = name,
                heading = options.rotation or 0,
                debugPoly = targetDebug(),
                minZ = coords.z - sz / 2,
                maxZ = coords.z + sz / 2,
            }, targetOptions)
            success = true
        elseif zoneType == 'ped' then
            exports['qb-target']:AddTargetEntity(options.entity, {
                options = targetOptions.options,
                distance = targetOptions.distance,
            })
            success = true
        end
    end

    if success then
        CreatedZones[name] = {
            zoneType = zoneType,
            coords = coords,
            size = size,
            options = options,
        }
    end
    return success
end

-- ox_target's removeZone/removeLocalEntity and qb-target's equivalents return
-- nothing, so their return value cannot be used as a success flag: this
-- reported failure for removals that had in fact worked. Success is decided
-- from our own bookkeeping instead -- did we know this target, and did the
-- provider call complete without error?
Target.Remove = function(name, isPed)
    if not Target.Available() then
        CreatedZones[name] = nil
        return false, 'no target provider started'
    end
    local entry = CreatedZones[name]
    if not entry then
        return false, ('no target named %s'):format(tostring(name))
    end
    if isPed and not (entry.options and entry.options.entity) then
        return false, 'target was not created for a local entity'
    end

    local kind = targetType()
    local ok, err = pcall(function()
        if kind == 'ox_target' then
            if isPed then
                exports.ox_target:removeLocalEntity(entry.options.entity)
            else
                exports.ox_target:removeZone(name)
            end
        elseif kind == 'qb-target' then
            if isPed then
                exports['qb-target']:RemoveTargetEntity(entry.options.entity)
            else
                exports['qb-target']:RemoveZone(name)
            end
        end
    end)

    if not ok then
        return false, tostring(err)
    end
    CreatedZones[name] = nil
    return true
end

Target.Update = function(name, newOptions)
    if not CreatedZones[name] then
        return false
    end
    local zoneInfo = CreatedZones[name]
    Target.Remove(name, zoneInfo.zoneType == 'ped')
    return Target.Create(zoneInfo.zoneType, name, zoneInfo.coords, zoneInfo.size, newOptions)
end

Target.Exists = function(name)
    return CreatedZones[name] ~= nil
end

exports('CreateTarget', Target.Create)
exports('RemoveTarget', Target.Remove)
exports('UpdateTarget', Target.Update)
exports('TargetExists', Target.Exists)
exports('TargetAvailable', Target.Available)
