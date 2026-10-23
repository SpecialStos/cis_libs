-- Server-side entity work needs OneSync; a table field named state does not.
local report = { state = 'idle' }
print(report.state)

RegisterNetEvent('bad:spawn', function()
    local src = source
    local ped = GetPlayerPed(src)
    print(ped)
end)
