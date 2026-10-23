if IsDuplicityVersion() then
    RegisterNetEvent('fixture:sharedServer', function()
        local src = source
        print(src)
    end)
else
    RegisterNetEvent('fixture:sharedClient', function(payload)
        print(payload)
    end)
end
