RegisterServerEvent("cis_libs:server:getData")
AddEventHandler("cis_libs:server:getData", function()
    local src = source

    local data = {
        Config = Config,
        Security = Security,
    }

    TriggerClientEvent("cis_libs:client:getData", src, data)
end)