-- Target abstraction.

local Target = {}
local CreatedZones = {}
-- Which name-collisions have already been logged.
local collisionWarned = {}
local warnedMissing = false
-- who asked for which target, so a consumer's stop removes its own zones through
local owned = CisOwned.new()

local function targetEnabled()
    return not (Config and Config.Framework and Config.Framework.Target and Config.Framework.Target.Enabled == false)
end

local function targetDebug()
    return Config and Config.Framework and Config.Framework.Target and Config.Framework.Target.Debug
end

function Target.Available()
    if not targetEnabled() then
        return false
    end
    local ok, available = CisRegistry.call('target', 'available')
    return ok and available == true
end

-- Which provider is answering, for the debug command.
function Target.ProviderName()
    local ok, name = CisRegistry.call('target', 'named')
    return ok and name or nil
end

-- The one warning per session, not per call.
local function missingOnce()
    if warnedMissing then
        return
    end
    warnedMissing = true
    CisLog('warn', 'No target provider registered')
end

Target.Create = function(zoneType, name, coords, size, options)
    -- Refusals return a reason as a second value: a caller across the exports boundary
    if not CisReadyState.wait(15000) then
        return false, 'cis_libs never became ready'
    end
    options = options or {}
    -- Read HERE, while the export is executing and GetInvokingResource() still names
    local owner = GetInvokingResource() or 'cis_libs'
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

    local spec = {
        zoneType = zoneType,
        name = name,
        coords = coords,
        size = size,
        rotation = options.rotation or 0,
        debug = targetDebug(),
        targetOptions = {
            options = options.options or {},
            distance = options.distance or 2.0,
        },
        -- Carried whole so the provider is handed the caller's entity handle rather
        options = options,
    }

    -- [D3] REFUSED, WITH THE HOLDER NAMED -- same rule as zones, and the same reason
    local holder = CreatedZones[name] and CreatedZones[name].owner
    if holder and holder ~= owner then
        -- Warn once per (name, holder, requester).
        local key = table.concat({ name, tostring(holder), tostring(owner) }, '\29')
        if not collisionWarned[key] then
            collisionWarned[key] = true
            CisLog('warn', ('target %q is already registered by %s; %s was refused. '
                .. 'Further refusals for this name will not be logged again.')
                :format(name, tostring(holder), tostring(owner)))
        end
        return false, ('target %q is already registered by %s; pick a different name')
            :format(name, tostring(holder))
    end

    local ok, reason = CisRegistry.call('target', 'create', spec)
    if not ok or reason == false then
        return false, ok and 'the target provider refused this request' or reason
    end

    CreatedZones[name] = spec
    spec.owner = owner
    CisOwned.track(owned, spec.owner, 'target', name)
    return true
end

-- Success is decided from our own bookkeeping, not from the provider's return:
Target.Remove = function(name, isPed)
    if not Target.Available() then
        CreatedZones[name] = nil
        CisOwned.forget(owned, 'target', name)
        return false, 'no target provider started'
    end
    local entry = CreatedZones[name]
    if not entry then
        return false, ('no target named %s'):format(tostring(name))
    end
    if isPed and not (entry.options and entry.options.entity) then
        return false, 'target was not created for a local entity'
    end

    local ok, err = CisRegistry.call('target', 'remove', name, entry, isPed)
    if not ok then
        return false, err
    end
    CreatedZones[name] = nil
    -- Removed the ordinary way, so the ledger stops owing it.
    CisOwned.forget(owned, 'target', name)
    return true
end

-- A CONSUMER THAT STOPS HAS ITS TARGETS REMOVED THROUGH THE PROVIDER ().
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        return
    end
    local freed = CisOwned.release(owned, resource)
    local removed = 0
    for i = 1, #freed do
        if freed[i].kind == 'target' then
            local entry = CreatedZones[freed[i].id]
            local isPed = entry and entry.zoneType == 'ped'
            pcall(function()
                if Target.Available() and entry then
                    CisRegistry.call('target', 'remove', freed[i].id, entry, isPed)
                end
                CreatedZones[freed[i].id] = nil
                CisOwned.forget(owned, 'target', freed[i].id)
                removed = removed + 1
            end)
        end
    end
    if removed > 0 then
        CisLog('info', ('cis_libs: removed %d target(s) owned by %s'):format(removed, tostring(resource)))
    end
end)

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

-- CisOwned.count answers ONE number across every kind, so a per-owner breakdown has to
CisDiagnostics.Register('client', 'targets', function()
    return { total = CisOwned.count(owned) }
end)
