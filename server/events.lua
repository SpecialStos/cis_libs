RegisterServerEvent("cis_BetterFightEvolved:server:getData")
AddEventHandler("cis_BetterFightEvolved:server:getData", function()
    local src = source

    local data = {
        Config = Config,
        Security = Security,
    }

    TriggerClientEvent("cis_BetterFightEvolved:client:getData", src, data)
end)

RegisterServerEvent(Security.EventPrefix .. ':server:log')
AddEventHandler(Security.EventPrefix .. ':server:log', function(message, discordType)
    print("^2[cis_BetterFightEvolved] ^5" .. message)
    if(discordType == "master")then
        TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.MasterLogs, "Master Logs", message, 'lightblue', false)
    elseif(discordType == "error")then
        TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.MasterLogs, "Master Logs", message, 'red', false)
    elseif(discordType == "cheating")then
        TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.CheatingLogs, "Cheating Logs", message, 'red', true)
    else
        TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.MasterLogs, "Master Logs", message, 'lightblue', false)
    end    
end)

Citizen.CreateThread(function()
    if Config.Crosshair.Enabled then
        RegisterServerEvent(Security.EventPrefix .. ':server:getCrosshairSettings')
        AddEventHandler(Security.EventPrefix .. ':server:getCrosshairSettings', function(targetPlayerId)
            local src = source
            TriggerClientEvent(Security.EventPrefix .. ':client:requestCrosshairSettings', targetPlayerId, src)
        end)

        RegisterServerEvent(Security.EventPrefix .. ':server:sendCrosshairSettings')
        AddEventHandler(Security.EventPrefix .. ':server:sendCrosshairSettings', function(requestingPlayerId, settings)
            TriggerClientEvent(Security.EventPrefix .. ':client:receiveCrosshairSettings', requestingPlayerId, settings)
        end)        
    end
end)