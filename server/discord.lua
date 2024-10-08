-- cis_libs/server/discord.lua

local Discord = {}

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

-- Function to send Discord log
function Discord.SendLog(webhookURL, title, message, color, ping)
    if not Config.Printing.UseDiscordLogs then return end

    local version = GetResourceMetadata(GetCurrentResourceName(), 'version')

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
end

-- Export the SendLog function
exports('SendDiscordLog', Discord.SendLog)

return Discord