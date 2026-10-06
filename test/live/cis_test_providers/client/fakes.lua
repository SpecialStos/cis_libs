-- Client-side capability fakes.
--
-- Only the slots the CLIENT actually resolves are here: framework, target and
-- doorsClient. The other seven are server-only, and a fake for a slot the client
-- never asks about is a slot whose "resolved" status says nothing.
--
-- The method signature trap from server/fakes.lua applies identically: no
-- leading `self`, because cis_libs dispatches with the caller's arguments only.

local function method(slot, name, answers)
    return function(...)
        local args = table.pack(...)
        CisTestRing.Record(slot, name, args)

        local fault = CisTestRing.ApplyFault(slot, name)
        if fault == true then
            return nil
        elseif fault == 'false_reason' then
            return false, ('cis_test_providers: injected refusal on %s.%s'):format(slot, name)
        elseif fault == 'wrong_shape' then
            return 'not-a-number', false
        end

        return answers(args)
    end
end

local framework = {
    get = method('framework', 'get', function() return {} end),
    ShowNotification = method('framework', 'ShowNotification', function() return nil end),
    IsLoaded = method('framework', 'IsLoaded', function() return true end),
    HasPermission = method('framework', 'HasPermission', function() return true end),
}

local target = {
    available = method('target', 'available', function() return true end),
    create = method('target', 'create', function() return true end),
    remove = method('target', 'remove', function() return true end),
    exists = method('target', 'exists', function() return true end),
    named = method('target', 'named', function() return 'cis_test_target' end),
}

-- doorsClient is the client half of the doors capability: the server owns the
-- doors and the client only knows what it has been told, so these are reads
-- over a pushed snapshot. `closest` answers nil rather than a fabricated door,
-- because a fake that invents a door makes a distance assertion pass against
-- data the real client would never have.
--
-- `RequestState` is here because the library asks for it through the slot, and a
-- fake without it sends every door request down the EVENT FALLBACK instead --
-- which is indistinguishable, from the outside, from a library that never
-- changed. With it missing, the one case that can tell a provider-backed
-- request from a raw event has nothing to tell.
local doorsClient = {
    add = method('doorsClient', 'add', function() return true end),
    addGroup = method('doorsClient', 'addGroup', function() return true end),
    closest = method('doorsClient', 'closest', function() return nil end),
    state = method('doorsClient', 'state', function() return false end),
    RequestState = method('doorsClient', 'RequestState', function() return true end),
}

local PROVIDERS = {
    framework = framework,
    target = target,
    doorsClient = doorsClient,
}

for slot, tbl in pairs(PROVIDERS) do
    exports('Provider_' .. slot, function(_self)
        return tbl
    end)
end

CreateThread(function()
    local waited = 0
    while GetResourceState('cis_libs') ~= 'started' and waited < 100 do
        Wait(100)
        waited = waited + 100
    end
    if GetResourceState('cis_libs') ~= 'started' then
        print('[cis_test_providers:client] cis_libs never started; no slot was claimed')
        return
    end
    for slot in pairs(PROVIDERS) do
        local ok, why = exports['cis_libs']:RegisterCapability(slot, 'cis_test_providers:Provider_' .. slot)
        if not ok then
            print(('[cis_test_providers:client] REFUSED %s: %s'):format(slot, tostring(why)))
        end
    end
    print(('[cis_test_providers:client] claimed %d slot(s)'):format(#PROVIDERS))
end)

exports('GetCalls', function(slot, methodName)
    if type(slot) ~= 'string' then return false, 'slot name required' end
    return CisTestRing.GetCalls(slot, methodName)
end)

exports('ResetCalls', function(slot)
    return CisTestRing.ResetCalls(slot)
end)