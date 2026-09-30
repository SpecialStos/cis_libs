-- Console and Discord logging, and the error reporter every other server file
-- funnels its failures through.
--
-- Two destinations with two different shapes, deliberately: the console gets a
-- single tagged line that stays readable in a busy server log, and Discord
-- gets the expanded version with file, line, event and stack trace. Nobody
-- wants a seven-line trace on a console that is already scrolling.

Logging = {
    Levels = {
        DEBUG = 1,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
    },
}

local Colors = {
    reset = '^0',
    red = '^1',
    green = '^2',
    yellow = '^3',
    cyan = '^5',
    white = '^7',
}

local function debugEnabled()
    -- Read per call rather than captured at load, so turning debug on from the
    -- console takes effect immediately without a resource restart. Every level
    -- check in here is a function call for the same reason.
    return Config and Config.Printing and Config.Printing.Debug
end

-- `discordType` picks a CHANNEL, not a severity -- the severity is `level`.
-- 'cheating' routes to the cheating channel because that is where an operator
-- looks for "a client did something wrong", which is a different question from
-- "something errored". Both are forwarded to Discord with an @everyone ping;
-- everything else goes to the master channel unpinged.
function Logging.Log(message, level, discordType, errorInfo)
    level = level or Logging.Levels.INFO
    if level == Logging.Levels.DEBUG and not debugEnabled() then
        return
    end

    local tag = 'INFO'
    local color = Colors.white
    if level == Logging.Levels.DEBUG then
        tag, color = 'DEBUG', Colors.cyan
    elseif level == Logging.Levels.WARN then
        tag, color = 'WARN', Colors.yellow
    elseif level == Logging.Levels.ERROR then
        tag, color = 'ERROR', Colors.red
    elseif level == Logging.Levels.INFO then
        color = Colors.green
    end

    -- Console output is unconditional and happens BEFORE every Discord check.
    -- The console is the destination that cannot be switched off by a config
    -- mistake, and it is what an operator reads when Discord is not configured.
    print(('%s[cis_libs] [%s] %s%s'):format(color, tag, tostring(message), Colors.reset))

    if not (Config and Config.Printing and Config.Printing.UseDiscordLogs) then
        return
    end
    -- Defensive. server/discord.lua loads first in fxmanifest, so at runtime
    -- this global always exists; the check is here so that reordering the
    -- manifest, or loading logging.lua into another resource, degrades to
    -- console-only instead of raising on every log line.
    if not DiscordQueue then
        return
    end

    local discordColor = 'lightblue'
    if level == Logging.Levels.ERROR then
        discordColor = 'red'
    elseif level == Logging.Levels.WARN then
        discordColor = 'yellow'
    end

    -- The expansion is Discord-only. The console line above is already printed
    -- in its short form and is not repeated.
    local discordMessage = tostring(message)
    if errorInfo then
        discordMessage = discordMessage .. '\n\nError Details:\nFile: ' .. tostring(errorInfo.file)
            .. '\nLine: ' .. tostring(errorInfo.line)
            .. '\nEvent: ' .. tostring(errorInfo.event or 'N/A')
            .. '\n\nStack Trace:\n' .. tostring(errorInfo.stackTrace)
    end

    local prefix = '[cis_libs] [' .. tag .. ']'
    local links = DiscordConfig and DiscordConfig.DiscordLogsLinks or {}
    if discordType == 'cheating' then
        DiscordQueue.push(links.CheatingLogs, prefix, discordMessage, 'red', true)
    elseif discordType == 'error' then
        -- Falls back to the master channel when ErrorLogs is unset, so a config
        -- with no dedicated error webhook still gets its errors. DiscordQueue
        -- discards the message if BOTH are unset or still hold CHANGE-ME, so
        -- an unconfigured install posts nothing rather than posting to a
        -- placeholder.
        DiscordQueue.push(links.ErrorLogs or links.MasterLogs, prefix, discordMessage, 'red', true)
    else
        DiscordQueue.push(links.MasterLogs, prefix, discordMessage, discordColor, false)
    end
end

-- Thin wrappers, so the numeric Levels do not leak into every call site and a
-- new level is one line here rather than an edit at every caller.
function Logging.Debug(message, discordType)
    Logging.Log(message, Logging.Levels.DEBUG, discordType)
end

function Logging.Info(message, discordType)
    Logging.Log(message, Logging.Levels.INFO, discordType)
end

function Logging.Warn(message, discordType)
    Logging.Log(message, Logging.Levels.WARN, discordType)
end

function Logging.Error(message, discordType, errorInfo)
    Logging.Log(message, Logging.Levels.ERROR, discordType, errorInfo)
end

-- The pcall wrapper in server/security.lua calls this. Two details make it
-- worth reading carefully:
--
--   getinfo(2) is the level that matters. Level 1 would be Logging.Error
--   itself, so every error in the library would be reported as originating in
--   logging.lua. Level 2 is the caller of AutoLogError -- the pcall site, and
--   therefore the event handler that actually failed.
--
--   `event` is the net event name, passed by CisNetOn. It is the field an
--   operator can grep for, and it is often more useful than the line number.
function Logging.AutoLogError(err, event)
    local info = debug.getinfo(2, 'Sl') or {}
    Logging.Error('Automatic Error Log:\n' .. tostring(err), 'error', {
        file = info.short_src,
        line = info.currentline,
        event = event,
        stackTrace = debug.traceback(err, 2),
        -- Recorded because the same handler behaves differently on different
        -- frameworks, and an error report that does not say which one it came
        -- from sends the reader to the wrong source.
        framework = Config and Config.Framework and Config.Framework.Type or 'NONE',
    })
end

-- String levels, not the numeric ones. This is the form consumers call --
-- `CisLog('warn', ...)` -- and it is kept separate from Logging.Log rather than
-- merged, because the numeric Levels are an internal detail and a string
-- literal in an export's signature is a stable contract. An unrecognised level
-- falls through to INFO rather than being dropped, so a typo loses severity
-- and not the message.
function CisLog(level, message, discordType)
    if level == 'error' then
        Logging.Error(message, discordType)
    elseif level == 'warn' then
        Logging.Warn(message, discordType)
    elseif level == 'debug' then
        Logging.Debug(message, discordType)
    else
        Logging.Info(message, discordType)
    end
end

-- The function VALUES, not wrappers. A wrapper would sit between a consumer's
-- call and the log line for no gain, and these are the functions the internal
-- call sites already use, so exporting them keeps one implementation.
exports('LogDebug', Logging.Debug)
exports('LogInfo', Logging.Info)
exports('LogWarn', Logging.Warn)
exports('LogError', Logging.Error)
exports('AutoLogError', Logging.AutoLogError)
exports('GetLogging', function()
    return Logging
end)
