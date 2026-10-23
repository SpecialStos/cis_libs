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

RegisterNetEvent('bad:loop', function(ids)
    for _, id in ipairs(ids) do
        print(id, source)
        Wait(10)
    end
end)

RegisterNetEvent('bad:thread', function()
    local src = source
    CreateThread(function()
        Wait(1000)
        TriggerClientEvent('bad:reply', source, src)
    end)
end)

RegisterNetEvent('bad:queryCallback', function()
    local src = source
    MySQL.query('SELECT 1', {}, function(rows)
        print(rows, source, src)
    end)
end)

RegisterNetEvent('bad:localShadow', function(data)
    local source = data.id
    print(source)
end)

local inv2 <const> = exports['ox_inventory']
RegisterNetEvent('bad:constAlias', function()
    inv2:Search(1, 'count', 'water')
    print(source)
end)

QBCore2 = exports['qb-core']:GetCoreObject()
RegisterNetEvent('bad:coreObjectFirst', function()
    local player = QBCore2.Functions.GetPlayer(source)
    print(player)
end)

RegisterNetEvent('bad:coreObjectAgain', function()
    local src = source
    QBCore2.Player.Save(src)
    print(source)
end)

RegisterNetEvent('bad:laterCitizen', function()
    local src = source
    Citizen.SetTimeout(500, function() print(source, src) end)
end)

RegisterNetEvent('bad:laterLib', function()
    local src = source
    lib.callback('fixture:cb', src, function() print(source) end)
end)

RegisterNetEvent('bad:laterHttp', function()
    local src = source
    PerformHttpRequest('https://example.invalid', function() print(source, src) end)
end)

RegisterNetEvent('bad:sync', function()
    MySQL.Sync.fetchAll('SELECT 1')
    print(source)
end)

RegisterNetEvent('bad:citizenAwait', function(p)
    Citizen.Await(p)
    print(source)
end)
