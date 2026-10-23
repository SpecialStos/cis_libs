-- Each net handler gets identity wrong. Line numbers are pinned in expect.json.
RegisterNetEvent('bad:payloadIdentity', function(target, amount)
    print(target, amount)
end)

RegisterNetEvent('bad:afterExports', function()
    local player = exports.cis_libs:GetPlayer(1)
    local src = source
    print(player, src)
end)

RegisterNetEvent('bad:afterWait', function()
    Wait(100)
    print(source)
end)

RegisterNetEvent('bad:afterAwait', function()
    local rows = MySQL.query.await('SELECT 1')
    print(rows, source)
end)

RegisterNetEvent('bad:shadowed', function(source)
    print(source)
end)

RegisterNetEvent('bad:onlyLater', function()
    CreateThread(function()
        print(source)
    end)
end)

RegisterServerEvent('bad:twoStep')
AddEventHandler('bad:twoStep', function(src)
    print(src)
end)

RegisterNetEvent('bad:external', Handlers.onBuy)

-- cis-lint: allow L002
RegisterNetEvent('bad:allowWithoutReason', function()
    print('x')
end)

RegisterNetEvent('bad:reRead', function()
    local src = source
    Wait(100)
    TriggerClientEvent('bad:reply', source, src)
end)

local inv = exports.ox_inventory
RegisterNetEvent('bad:alias', function()
    local count = inv:Search(1, 'count', 'water')
    print(count, source)
end)

RegisterNetEvent('bad:waitFor', function()
    lib.waitFor(function() return true end)
    print(source)
end)

RegisterNetEvent('bad:crossFile')
