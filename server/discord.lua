-- Discord webhook queue. Bounded, rate-limited, and it never blocks the
-- caller: a slow or dead webhook drops the oldest entries rather than growing
-- without limit.

DiscordQueue = {
    items = {},
    dropped = 0,
}

local MAX_QUEUE = 100
local colors = {
    default = 0,
    white = 16777215,
    black = 0,
    red = 16711680,
    green = 65280,
    blue = 255,
    orange = 16753920,
    yellow = 16776960,
    lightblue = 8900331,
}

local lastSend = 0
local SEND_INTERVAL = 1200
local FAILURE_BACKOFF = 15000
local consecutiveFailures = 0

function DiscordQueue.enabled()
    return Config and Config.Printing and Config.Printing.UseDiscordLogs
end

local function usable(url)
    return type(url) == 'string' and url ~= '' and not url:find('CHANGE-ME', 1, true)
end

local function embedPayload(title, message, color)
    local cfg = DiscordConfig or {}
    local version = GetResourceMetadata(GetCurrentResourceName(), 'version', 0)
    return {
        username = 'cis_libs',
        embeds = {
            {
                author = { name = 'cis_libs  -  Version: ' .. tostring(version) },
                color = colors[color] or colors.default,
                title = '**' .. tostring(title) .. '**',
                description = tostring(message),
                thumbnail = cfg.Thumbnail and { url = cfg.Thumbnail } or nil,
                footer = {
                    text = cfg.FooterText,
                    icon_url = cfg.FooterIcon,
                },
            },
        },
    }
end

function DiscordQueue.push(url, title, message, color, ping)
    if not DiscordQueue.enabled() then
        return false
    end
    if not usable(url) then
        return false
    end
    if #DiscordQueue.items >= MAX_QUEUE then
        -- Drop the oldest: a stale INFO line is worth less than a live ERROR.
        table.remove(DiscordQueue.items, 1)
        DiscordQueue.dropped = DiscordQueue.dropped + 1
    end
    DiscordQueue.items[#DiscordQueue.items + 1] = {
        url = url,
        title = title,
        message = message,
        color = color,
        ping = ping,
    }
    return true
end

local function post(item)
    local body = json.encode(embedPayload(item.title, item.message, item.color))
    PerformHttpRequest(item.url, function(status)
        if status ~= 200 and status ~= 204 then
            consecutiveFailures = consecutiveFailures + 1
        else
            consecutiveFailures = 0
        end
    end, 'POST', body, {
        ['Content-Type'] = 'application/json',
    })

    if item.ping then
        PerformHttpRequest(item.url, function() end, 'POST', json.encode({ content = '@everyone' }), {
            ['Content-Type'] = 'application/json',
        })
    end
end

CreateThread(function()
    while true do
        if #DiscordQueue.items == 0 then
            Wait(1000)
        else
            local wait = SEND_INTERVAL
            if consecutiveFailures > 0 then
                -- Back off while the endpoint is unhappy instead of hammering it.
                wait = FAILURE_BACKOFF * math.min(4, consecutiveFailures)
            end
            local since = GetGameTimer() - lastSend
            if since < wait then
                Wait(wait - since)
            else
                -- Drain in a small batch so a burst is not paced at one
                -- message per interval forever.
                for _ = 1, math.min(#DiscordQueue.items, 5) do
                    if #DiscordQueue.items == 0 then
                        break
                    end
                    post(table.remove(DiscordQueue.items, 1))
                    lastSend = GetGameTimer()
                end
            end
        end
    end
end)

exports('SendDiscordLog', function(webhookURL, title, message, color, ping)
    return DiscordQueue.push(webhookURL, title, message, color, ping)
end)

exports('GetDiscordQueueDepth', function()
    return #DiscordQueue.items, DiscordQueue.dropped
end)
