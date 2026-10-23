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
