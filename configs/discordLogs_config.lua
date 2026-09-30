-- =============================================================================
--  cis_libs -- Discord logging configuration  (SERVER SIDE ONLY)
--
--  The master switch is NOT in this file. It is:
--
--      Config.Printing.UseDiscordLogs = false        (master_config.lua)
--
--  While that is false, everything below is inert: no queue, no request, no
--  outbound traffic of any kind.
--
--  When you turn it on, the webhook URLs below become LIVE SECRETS. Anyone
--  holding one can read that channel, and for two of the three channels they
--  can also post into it. A webhook URL is a password. Do not paste one into a
--  Discord channel, a screenshot, a pastebin, a GitHub issue, or another
--  resource's config.
--
--  WHAT EACH CHANNEL RECEIVES:
--
--    MasterLogs   -- informational messages. The only quiet channel.
--    CheatingLogs -- security detections. PINGS @everyone.
--    ErrorLogs    -- errors AND stack traces. PINGS @everyone.
--
--  Read that twice before enabling ErrorLogs. An error entry carries the
--  server-side file path, the line number, the event that failed and the full
--  Lua stack trace. If that channel is not one you control end to end, every
--  error in your server is a partial map of your resource layout being handed
--  to a third party. ErrorLogs falls back to MasterLogs when it is unset, so
--  the safe way to run is: leave ErrorLogs empty and use MasterLogs for both.
--
--  DELIVERY BEHAVIOUR, so nothing here is a surprise at 3am: messages are
--  paced roughly one batch every 1.2s, the queue is capped at 100 entries and
--  drops the OLDEST when full, and a failing webhook backs the sender off
--  instead of hammering it. A dropped message is counted, not retried.
-- =============================================================================

DiscordConfig = {}

-- Cosmetics on the embed. These are plain URLs in the JSON body: Discord's
-- CLIENT fetches them, so they cause no outbound request from your server.
--
-- The two i.imgur.com URLs and the footer text below ship as the publisher's
-- own branding. They are not secrets and they name nobody's server, but if you
-- run your own Discord, replace them: FooterText in particular is the one line
-- of this library that ends up in front of your staff.
DiscordConfig.Thumbnail = "https://i.imgur.com/s1Y6ykF.png"
DiscordConfig.FooterText = "fivem.cisoko.net - Shaping the Future of Roleplaying Games"
DiscordConfig.FooterIcon = "https://i.imgur.com/Ah7nsiv.png"

-- -----------------------------------------------------------------------------
--  THE WEBHOOKS.
--
--  SAFE AS SHIPPED, AND ENFORCED, NOT JUST HOPED: every URL below still holds
--  the CHANGE-ME marker, and the queue refuses any destination containing that
--  marker. So flipping Config.Printing.UseDiscordLogs to true before you paste
--  real URLs does NOT send traffic to a broken address -- it silently sends
--  nothing at all. You cannot leak an outbound request by enabling logs first
--  and filling the webhooks in later.
--
--  The cost of that safety is silence rather than an error, so if you turn
--  logging on and see no messages, check for CHANGE-ME here first.
--
--  TO SET ONE: in Discord, Server Settings -> Integrations -> Webhooks, create
--  a webhook, "Copy Webhook URL", and paste the whole
--  https://discord.com/api/webhooks/... string as the value. Nothing else
--  needs editing.
--
--  These values are stripped from the payload sent to clients, so a player
--  cannot read a webhook URL back out of the game.
-- -----------------------------------------------------------------------------
DiscordConfig.DiscordLogsLinks = {
    MasterLogs = "CHANGE-ME-WITH-YOUR-WEBHOOK-LINK",
    CheatingLogs = "CHANGE-ME-WITH-YOUR-WEBHOOK-LINK",

    -- Leave this one as-is to have errors go to MasterLogs instead of their own
    -- channel. Give it its own webhook only if you want its @everyone ping.
    ErrorLogs = "CHANGE-ME-WITH-YOUR-WEBHOOK-LINK",
}

-- Kept as an alias so older snippets that read `Discord` still compile on the
-- server. Both names are process-global, so a resource that also defines
-- `Discord` shares this table with it.
Discord = DiscordConfig