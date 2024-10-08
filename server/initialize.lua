-- cis_libs/server/initialize.lua

RegisterServerEvent("cis_libs:server:getData")
AddEventHandler("cis_libs:server:getData", function()
    local src = source

    local data = {
        Config = Config,
        Security = Security,
        DoorData = exports['cis_libs']:GetAllDoorData()
    }

    TriggerClientEvent("cis_libs:client:getData", src, data)
    
    if Config.Printing and Config.Printing.Debug then
        exports['cis_libs']:LogDebug("Sent initial data including door information to player " .. src)
    end
end)