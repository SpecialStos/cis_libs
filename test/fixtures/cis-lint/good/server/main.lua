-- Correct server net handlers.
local function openFor(src)
    print(exports.cis_libs:GetPlayer(src))
end

RegisterNetEvent('fixture:local', function(amount)
    local src = source
    local player = exports.cis_libs:GetPlayer(src)
    Wait(0)
    print(player, amount)
end)

RegisterNetEvent('fixture:argument', function()
    openFor(source)
end)

local function dispatch(name, ...)
    local src = source
    Wait(0)
    print(name, src, ...)
end

RegisterNetEvent('fixture:dispatch', function(...)
    return dispatch('fixture:dispatch', ...)
end)

RegisterNetEvent('fixture:twoStep')
AddEventHandler('fixture:twoStep', function()
    local src = source
    print(src)
end)

-- A local event, not a net event: no source needed.
AddEventHandler('onResourceStop', function(name)
    print(name)
end)

-- cis-lint: allow L002 a liveness ping; it reads no player state and answers nobody
RegisterNetEvent('fixture:ping', function()
    print('ping')
end)

print(GetPlayerPed(1), Entity(1).state.fuel, GlobalState.weather)
