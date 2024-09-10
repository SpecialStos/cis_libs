Citizen.CreateThread(function()
    if(Discord.UseDiscordLogs)then

        RegisterServerEvent(Security.EventPrefix .. ':server:log')
        AddEventHandler(Security.EventPrefix .. ':server:log', function(message, discordType)
            if(discordType == "master")then
                TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.MasterLogs, "Master Logs", message, 'lightblue', false)
            elseif(discordType == "cheating")then
                TriggerEvent(Security.EventPrefix .. ':server:sendDiscordLog', Discord.DiscordLogsLinks.CheatingLogs, "Cheating Logs", message, 'red', true)
            end    
        end)

        local version = GetResourceMetadata(GetCurrentResourceName(), 'version')
        RegisterNetEvent(Security.EventPrefix .. ':server:sendDiscordLog')
        AddEventHandler(Security.EventPrefix .. ':server:sendDiscordLog', function(webhookURL, title, message, color, ping)
            local discordColors = {
                ["default"] = 0,
                ["white"] = 16777215,
                ["black"] = 0,
                ["red"] = 16711680,
                ["green"] = 65280,
                ["blue"] = 255,
                ["orange"] = 16753920,
                ["yellow"] = 16776960,
                ["lightblue"] = 8900331,
                -- Add more colors here
            }
        
            if ping then
                PerformHttpRequest(webhookURL, function(err, text, headers) end, 'POST', json.encode({content = "@everyone"}), { ['Content-Type'] = 'application/json' })
                message = "@everyone " .. message
            end

            local embed = {
                {
                    ["author"] = {
                        name = "cis_libs  -  Version: " .. version,
                    },
                    ["color"] = discordColors[color] or discordColors.default,
                    ["title"] = "**".. title .."**",
                    ["description"] = message,
                    ["thumbnail"] = {
                        ["url"] = Discord.Thumbnail,
                    },
                    ["footer"] = {
                        ["text"] = Discord.FooterText,
                        ["icon_url"] = Discord.FooterIcon,
                    },
                }
            }

            PerformHttpRequest(webhookURL, function(err, text, headers) end, 'POST', json.encode({username = name, embeds = embed}), { ['Content-Type'] = 'application/json' })
        end)
    end

end)