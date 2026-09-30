-- Target abstraction.
--
-- This file used to contain the ox_target and qb-target calls, and that was
-- wrong in a way worth recording: the abstraction and the thing it abstracts
-- over were in one file, so "support a third target" meant editing the file
-- that owned the abstraction. The provider calls now live in cis_bridge, one
-- file each, and this file answers a question that is entirely about the
-- CALLER: is this target wanted, is this request well formed, and what should
-- the answer be if it is not.
--
-- What stayed is the part with no provider in it. The refusals and their exact
-- wording are published behaviour -- a consumer that reads the second return
-- value is parsing these strings -- so they are reproduced character for
-- character. `CreatedZones` stayed too, and it is load-bearing: it is the only
-- record of what this library believes it created, and remove and update decide
-- their success from it because both providers' removal calls return nothing
-- at all.
--
-- What moved is every `exports.ox_target:` and `exports['qb-target']:` call.
-- The provider is now a capability (cis_bridge registers it), and this file
-- hands it a plain spec table. The provider keeps no state: it is told what to
-- create and what to remove, which means a provider restart cannot leave this
-- side of the wire believing in a zone that no longer exists.

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

function Target.Available()
    if not targetEnabled() then
        return false
    end
    local ok, available = CisRegistry.call('target', 'available')
    return ok and available == true
end

-- Which provider is answering, for the debug command. nil means none, and that
-- is a different answer from 'ox_target configured but not started' -- the
-- second is a start-order bug and the first is a missing resource, and an
-- operator needs to be told which one they have.
function Target.ProviderName()
    local ok, name = CisRegistry.call('target', 'named')
    return ok and name or nil
end

-- The one warning per session, not per call. A target create is often on a hot
-- path, and a provider that is not started does not become started, so a
-- per-call warning is the same line thousands of times.
local function missingOnce()
    if warnedMissing then
        return
    end
    warnedMissing = true
    CisLog('warn', 'No target provider registered; install cis_bridge and start an ox_target or qb-target adapter')
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
        -- Carried whole so the provider is handed the caller's entity handle
        -- rather than this file having to know which field it arrives in.
        options = options,
    }

    local ok, reason = CisRegistry.call('target', 'create', spec)
    if not ok or reason == false then
        return false, ok and 'the target provider refused this request' or reason
    end

    CreatedZones[name] = spec
    return true
end

-- Success is decided from our own bookkeeping, not from the provider's return:
-- ox_target's removeZone/removeLocalEntity and qb-target's equivalents return
-- nothing, so their return value cannot be used as a flag. Reading it used to
-- report failure for removals that had in fact worked.
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

    local ok, err = CisRegistry.call('target', 'remove', name, entry, isPed)
    if not ok then
        return false, err
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
