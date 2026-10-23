-- Shared files load in both realms: an unguarded net handler is a server
-- handler too; the client branch of IsDuplicityVersion() is not.
RegisterNetEvent('bad:sharedUnguarded', function(target)
    print(target)
end)

if not IsDuplicityVersion() then
    RegisterNetEvent('fine:clientOnly', function(payload)
        print(payload)
    end)
end

if not IsDuplicityVersion() then
    print('client')
else
    RegisterNetEvent('bad:elseServer', function(t) print(t) end)
end

if Config then
    print('config')
elseif IsDuplicityVersion() then
    RegisterNetEvent('bad:elseifServer', function(t) print(t) end)
end

if IsDuplicityVersion() and Config then
    RegisterNetEvent('bad:andServer', function(t) print(t) end)
end

if IsDuplicityVersion() == false then
    RegisterNetEvent('fine:eqFalseClient', function(t) print(t) end)
else
    RegisterNetEvent('bad:eqFalseServer', function(t) print(t) end)
end

if not IsDuplicityVersion() or Config then
    RegisterNetEvent('bad:orServer', function(t) print(t) end)
end
