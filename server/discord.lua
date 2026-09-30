-- Discord webhook queue. Bounded, rate-limited, and it never blocks the
-- caller: a slow or dead webhook drops the oldest entries rather than growing
-- without limit.

DiscordQueue = {
    items = {},
    dropped = 0,
}

local MAX_QUEUE = 100
-- Discord accepts roughly 5 requests/5s per webhook. 1200ms is comfortably
-- under that and still lets a burst drain in seconds rather than minutes. The
-- real limit is not this number but the batch size below, which is why a
-- backlog is paced in groups rather than one message per interval.
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

-- A stock config ships placeholder URLs. Posting to one of those would send
-- every log line the server ever produces to whatever third party owns that
-- placeholder, so an unconfigured URL is treated as no URL at all and the
-- message is discarded silently -- the log line itself already went to the
-- console, which is the point of having two sinks.
local function usable(url)
    return type(url) == 'string' and url ~= '' and not url:find('CHANGE-ME', 1, true)
end

-- Built at send time, not push time: the version string is read from the
-- resource, and a config edit that lands while a message is queued should be
-- reflected in what is sent.
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
    -- Never raises and never blocks. Logging must not be able to fail or stall
    -- the code path that produced the log line, so every refusal below is a
    -- plain false the caller is free to ignore.
    if not DiscordQueue.enabled() then
        return false
    end
    if not usable(url) then
        return false
    end
    if #DiscordQueue.items >= MAX_QUEUE then
        -- Drop the oldest: a stale INFO line is worth less than a live ERROR.
        -- The count is kept because a silently truncating queue is how a server
        -- ends up with a webhook that looks fine and is missing its warnings.
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
    -- 200 and 204 are both success here: Discord answers 204 for a webhook
    -- with nothing to render. Treating 204 as a failure would put a server
    -- that posts a filtered-out log into a permanent backoff.
    PerformHttpRequest(item.url, function(status)
        if status ~= 200 and status ~= 204 then
            consecutiveFailures = consecutiveFailures + 1
        else
            consecutiveFailures = 0
        end
    end, 'POST', body, {
        ['Content-Type'] = 'application/json',
    })

    -- A separate request, not a field on the embed: Discord does not let an
    -- embed carry its own mention, so a ping is a second post to the same
    -- webhook. That is why a ping costs twice the rate-limit budget, and why
    -- the queue treats a pinged item as one item.
    if item.ping then
        PerformHttpRequest(item.url, function() end, 'POST', json.encode({ content = '@everyone' }), {
            ['Content-Type'] = 'application/json',
        })
    end
end

-- The one polling loop in this file. Two intervals:
--
--   1000ms -- how long an idle queue takes to notice the first new message.
--     Nothing happens in the body while empty, so the only cost of a shorter
--     wait is a scheduler wakeup per tick on the common case (logging on,
--     nothing to send). Nothing is lost by waiting this long either: a log line
--     that waits a second for a webhook is not late.
--
--   SEND_INTERVAL, or the backoff -- the pacing between bursts, enforced by
--     sleeping the REMAINING time rather than a fixed wait, so a batch that
--     overruns does not push the next one further out.
CreateThread(function()
    while true do
        if #DiscordQueue.items == 0 then
            Wait(1000)
        else
            local wait = SEND_INTERVAL
            if consecutiveFailures > 0 then
                -- Back off while the endpoint is unhappy instead of hammering
                -- it. Capped at 4x (60s) because an endpoint that has been
                -- down for an hour is not going to be reached by a longer
                -- wait, and a queue that backs off without limit is a queue
                -- that never recovers when the endpoint comes back.
                wait = FAILURE_BACKOFF * math.min(4, consecutiveFailures)
            end
            local since = GetGameTimer() - lastSend
            if since < wait then
                Wait(wait - since)
            else
                -- Drain in a small batch so a burst is not paced at one
                -- message per interval forever. Five is a batch, not a rate:
                -- the next burst still waits a full interval, so a server with
                -- a 100-deep backlog drains in about 24s and a server sending
                -- one line a second is unaffected.
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

-- Depth AND cumulative drops, because depth alone looks healthy on a server
-- that has been quietly truncating for an hour. A rising `dropped` counter is
-- the only signal an operator gets that the webhook is not keeping up.
exports('GetDiscordQueueDepth', function()
    return #DiscordQueue.items, DiscordQueue.dropped
end)
